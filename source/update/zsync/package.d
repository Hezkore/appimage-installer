// Pure D zsync delta update implementation
// Applies .zsync patches without external binaries by reusing matching blocks and downloading only what changed
//
module update.zsync;

import std.algorithm : min;
import std.array : appender;
import std.conv : to;
import std.digest.sha : SHA1;
import std.exception : ErrnoException;
import std.file : exists, remove, getSize, mkdirRecurse;
import std.file : FileException;
import std.net.curl : HTTP, CurlException;
import std.path : buildPath, dirName;
import std.stdio : File, writeln;
import std.string : startsWith, strip, splitLines, indexOf, lastIndexOf, split;

import update.common : readManifestFields, finishInstall, MAX_HTTP_REDIRECTS;
import update.zsync.md4 : computeMd4;
import types : InstallMethod;
import constants : APPLICATIONS_SUBDIR, UPDATE_SUBDIR;

// Progress fractions marking each phase of the zsync update
private enum Progress {
	start = 0.0,
	afterManifest = 0.1,
	afterMeta = 0.2,
	afterMatching = 0.4,
	afterDownload = 0.6,
	complete = 1.0,
}

// Parsed contents of a .zsync metafile
private struct ZsyncMeta {
	uint blocksize;
	ulong length;
	uint numBlocks;
	uint rsumLen;
	uint checksumLen;
	uint seqMatches;
	string fileUrl;
	ubyte[20] sha1;
	ubyte[] blockTable;
}

// True when updateInfo encodes a zsync update method
public bool isZsync(string updateInfo) {
	import update.common : parseUpdateMethodKind, UpdateMethodKind;

	return parseUpdateMethodKind(updateInfo) == UpdateMethodKind.Zsync;
}

// Extracts the .zsync metafile URL from a zsync updateInfo string
public string extractZsyncUrl(string updateInfo) {
	return updateInfo["zsync|".length .. $];
}

// Rolling checksum (rsum) matching zsync's formula so block table entries compare correctly

// Represents the rolling checksum state over one block-width window
private struct Rsum {
	ushort a, b;
}

// Computes rsum for data[0..blocksize), following zsync's init loop order
private Rsum rsumInit(const(ubyte)[] data, uint blocksize) {
	ushort a = 0, b = 0;
	foreach (i; 0 .. blocksize) {
		ubyte c = data[i];
		a = cast(ushort)(a + c);
		// zsync's init loop counts len down, weight for data[i] is (blockSize-1-i)
		b = cast(ushort)(b + (blocksize - 1 - i) * c);
	}
	return Rsum(a, b);
}

// Slides rsum one byte forward, following zsync's update_rsum formula
private void rsumRoll(
	ref Rsum r, ubyte leaving, ubyte arriving, uint blockSize) {
	r.a = cast(ushort)(r.a + arriving - leaving);
	// In zsync, b += a - Blocksize * unout  (a is already the new value)
	r.b = cast(ushort)(r.b + r.a - cast(ushort)(blockSize * leaving));
}

// Encodes rsum as a masked uint for hashtable lookup
// Format is (a & 0xffff) | ((b & 0xffff) << 16), little-endian, rsumLen bytes
private uint rsumMasked(Rsum r, uint rsumLen) {
	uint encoded = (cast(uint) r.a & 0xffff) | ((cast(uint) r.b & 0xffff) << 16);
	if (rsumLen >= 4)
		return encoded;
	return encoded & ((1u << (8 * rsumLen)) - 1);
}

// Block table helpers

// Reads the stored rsum for block blockIndex from the binary block table
private uint readBlockRsum(
	const(ubyte)[] table, size_t blockIndex, uint rsumLen, uint stride) {
	size_t tableOffset = blockIndex * stride;
	uint blockRsum = 0;
	foreach (byteOffset; 0 .. rsumLen)
		blockRsum |= cast(uint)(table[tableOffset + byteOffset]) << (8 * byteOffset);
	return blockRsum;
}

// Returns true when the stored MD4 prefix for blockIdx matches blockData
private bool checksumMatches(
	const(ubyte)[] table,
	size_t blockIndex,
	uint rsumLen,
	uint checksumLen,
	uint stride,
	const(ubyte)[] blockData) {
	auto digest = computeMd4(blockData);
	size_t tableOffset = blockIndex * stride + rsumLen;
	foreach (byteOffset; 0 .. checksumLen)
		if (digest[byteOffset] != table[tableOffset + byteOffset])
			return false;
	return true;
}

// Metafile parsing

// Parses a .zsync metafile from raw bytes baseUrl is the URL the file was fetched from, used to resolve relative URLs
private bool parseZsyncMeta(
	const(ubyte)[] raw,
	string baseUrl,
	out ZsyncMeta meta,
	out string error) {
	// Find the blank line separating text headers from binary block data
	size_t headerEnd = 0;
	for (size_t byteOffset = 0; byteOffset + 1 < raw.length; byteOffset++) {
		if (raw[byteOffset] == '\n' && raw[byteOffset + 1] == '\n') {
			headerEnd = byteOffset + 2;
			break;
		}
		if (byteOffset + 3 < raw.length
			&& raw[byteOffset] == '\r' && raw[byteOffset + 1] == '\n'
			&& raw[byteOffset + 2] == '\r' && raw[byteOffset + 3] == '\n') {
			headerEnd = byteOffset + 4;
			break;
		}
	}
	if (headerEnd == 0) {
		error = "No header separator found in .zsync file";
		return false;
	}

	string headers = cast(string)(raw[0 .. headerEnd].dup);
	meta.blockTable = cast(ubyte[])(raw[headerEnd .. $]).dup;

	bool hasBlocksize, hasLength, hasHashLengths, hasUrl, hasSha1;
	string urlField;

	foreach (line; headers.splitLines()) {
		auto colon = line.indexOf(':');
		if (colon < 0)
			continue;
		string key = line[0 .. colon].strip();
		string headerValue = line[colon + 1 .. $].strip();
		switch (key) {
		case "Blocksize":
			meta.blocksize = headerValue.to!uint;
			hasBlocksize = true;
			break;
		case "Length":
			meta.length = headerValue.to!ulong;
			hasLength = true;
			break;
		case "Hash-Lengths":
			// From zsync source, format is seq_matches,rsum_len,checksum_len
			auto parts = headerValue.split(',');
			if (parts.length != 3) {
				error = "Malformed Hash-Lengths: " ~ headerValue;
				return false;
			}
			meta.seqMatches = parts[0].strip().to!uint;
			meta.rsumLen = parts[1].strip().to!uint;
			meta.checksumLen = parts[2].strip().to!uint;
			hasHashLengths = true;
			break;
		case "URL":
			urlField = headerValue;
			hasUrl = true;
			break;
		case "SHA-1":
			if (headerValue.length != 40) {
				error = "Bad SHA-1 field length";
				return false;
			}
			foreach (i; 0 .. 20)
				meta.sha1[i] = cast(ubyte)(headerValue[i * 2 .. i * 2 + 2].to!uint(16));
			hasSha1 = true;
			break;
		default:
			break;
		}
	}

	if (!hasBlocksize || !hasLength || !hasHashLengths || !hasUrl || !hasSha1) {
		error = "Missing required .zsync header fields";
		return false;
	}

	// Resolve URL relative to the .zsync location if needed
	if (urlField.startsWith("http://") || urlField.startsWith("https://")) {
		meta.fileUrl = urlField;
	} else {
		auto lastSlash = baseUrl.lastIndexOf('/');
		meta.fileUrl = lastSlash >= 0
			? baseUrl[0 .. lastSlash + 1] ~ urlField : urlField;
	}

	meta.numBlocks = cast(uint)(
		(meta.length + meta.blocksize - 1) / meta.blocksize);

	size_t stride = meta.rsumLen + meta.checksumLen;
	if (meta.blockTable.length < meta.numBlocks * stride) {
		error = "Block table is shorter than expected";
		return false;
	}

	return true;
}

// Network helpers

// Downloads url into a buffer, only for small files like .zsync metafiles
private bool fetchBytes(
	string url, out ubyte[] data, out string error,
	bool delegate() shouldCancel = null) {
	auto responseBody = appender!(ubyte[])();
	auto http = HTTP(url);
	http.maxRedirects(MAX_HTTP_REDIRECTS);
	if (shouldCancel !is null)
		http.onProgress = (ulong dlTotal, ulong dlNow, ulong ulTotal, ulong ulNow) {
		return shouldCancel() ? 1 : 0;
	};
	http.onReceive = (ubyte[] chunk) {
		responseBody.put(chunk);
		return chunk.length;
	};
	try {
		http.perform();
	} catch (CurlException curlError) {
		error = curlError.msg;
		return false;
	}
	immutable uint code = http.statusLine.code;
	if (code < 200 || code >= 300) {
		error = "HTTP " ~ code.to!string;
		return false;
	}
	data = responseBody.data;
	return true;
}

// Verifies the SHA-1 of the file at path against expected
private bool verifySha1(
	string path, const(ubyte[20]) expected, out string error) {
	SHA1 sha;
	sha.start();
	auto f = File(path, "rb");
	ubyte[65_536] readBuffer;
	while (!f.eof) {
		auto chunk = f.rawRead(readBuffer[]);
		if (chunk.length == 0)
			break;
		sha.put(chunk);
	}
	f.close();
	auto actual = sha.finish();
	if (actual[] != expected[]) {
		error = "SHA-1 mismatch: file may be corrupt";
		return false;
	}
	return true;
}

// Delta application

// Scans existingPath for blocks and returns offsets per block index (-1 if unmatched)
// progress goes from progressStart to progressEnd as the file is scanned
private long[] matchExistingBlocks(
	ZsyncMeta meta, string existingPath,
	ref double progress, double progressStart, double progressEnd) {
	uint stride = meta.rsumLen + meta.checksumLen;
	uint blockSize = meta.blocksize;

	// For small rsumLen the key fits in 16 bits, use a flat array for O(1) direct access
	// Fall back to a hash map only when the key can exceed 16 bits
	immutable bool useFlatTable = meta.rsumLen <= 2;
	uint[][uint] rsumAA;
	uint[][] rsumFlat = useFlatTable ? new uint[][](65_536) : null;

	foreach (blockIndex; 0 .. meta.numBlocks) {
		uint rsum = readBlockRsum(meta.blockTable, blockIndex, meta.rsumLen, stride)
			& (
				meta.rsumLen < 4 ? (1u << (8 * meta.rsumLen)) - 1 : uint.max);
		if (useFlatTable)
			rsumFlat[rsum & 0xffff] ~= cast(uint) blockIndex;
		else
			rsumAA.require(rsum) ~= cast(uint) blockIndex;
	}

	long[] srcOff = new long[](meta.numBlocks);
	foreach (ref sourceOffset; srcOff)
		sourceOffset = -1;
	size_t matched = 0;

	if (!existingPath.length || !exists(existingPath)) {
		writeln("zsync: matchExistingBlocks: no source file, skipping scan");
		return srcOff;
	}

	ulong srcSize = getSize(existingPath);
	if (srcSize < blockSize)
		return srcOff;

	ubyte[] blockBuffer = new ubyte[](blockSize);

	// Fast path checks each block at its expected aligned offset in the existing file
	// Covers the common case in O(numBlocks) reads with no rolling hash or rsum table needed
	{
		auto f = File(existingPath, "rb");
		scope (exit)
			f.close();
		foreach (blockIndex; 0 .. meta.numBlocks) {
			ulong expectedOffset = cast(ulong) blockIndex * blockSize;
			if (expectedOffset + blockSize > srcSize)
				break;
			f.seek(expectedOffset);
			if (f.rawRead(blockBuffer[]).length < blockSize)
				break;
			if (!checksumMatches(meta.blockTable, blockIndex, meta.rsumLen, meta.checksumLen, stride, blockBuffer))
				continue;
			srcOff[blockIndex] = cast(long) expectedOffset;
			matched++;
		}
	}
	writeln("zsync: fast-path matched ", matched, " / ", meta.numBlocks, " aligned blocks");
	progress = progressStart + (progressEnd - progressStart) * 0.1;
	if (matched == meta.numBlocks) {
		writeln("zsync: all blocks matched, skipping rolling scan");
		progress = progressEnd;
		return srcOff;
	}
	// If nothing matched at all, the existing file is a completely different build
	// Rolling the entire file would waste time while yielding no reusable blocks
	if (matched == 0) {
		writeln("zsync: no aligned blocks matched, skipping rolling scan");
		progress = progressEnd;
		return srcOff;
	}

	// Rolling scan for blocks at non-aligned offsets using a seqMatches pre-filter
	// when seqMatches reaches 2 a lookahead rsum check rules out most false positives
	auto srcFile = File(existingPath, "rb");
	scope (exit)
		srcFile.close();

	immutable bool dualWindow = meta.seqMatches >= 2;
	ubyte[] circ = new ubyte[](blockSize);
	ubyte[] circ1 = dualWindow ? new ubyte[](blockSize) : null;

	if (srcFile.rawRead(circ[]).length < blockSize)
		return srcOff;
	if (dualWindow && srcFile.rawRead(circ1[]).length < blockSize)
		return srcOff;

	uint head = 0;
	Rsum r = rsumInit(circ, blockSize);
	Rsum r1 = dualWindow ? rsumInit(circ1, blockSize) : Rsum.init;

	immutable uint rsumMask = meta.rsumLen < 4 ? (1u << (8 * meta.rsumLen)) - 1 : uint.max;

	void tryMatch(ulong windowStart) {
		uint masked = rsumMasked(r, meta.rsumLen);
		uint[] pBlocks;
		if (useFlatTable)
			pBlocks = rsumFlat[masked & 0xffff];
		else {
			auto p = masked in rsumAA;
			if (p is null)
				return;
			pBlocks = *p;
		}
		if (pBlocks.length == 0)
			return;
		uint masked1 = dualWindow ? rsumMasked(r1, meta.rsumLen) : 0;
		bool blockDataCopied = false;
		foreach (blockIndex; pBlocks) {
			if (srcOff[blockIndex] >= 0)
				continue;
			if (dualWindow && blockIndex + 1 < meta.numBlocks) {
				uint nextRsum = readBlockRsum(
					meta.blockTable, blockIndex + 1, meta.rsumLen, stride) & rsumMask;
				if (nextRsum != masked1)
					continue;
			}
			if (!blockDataCopied) {
				foreach (bytePosition; 0 .. blockSize)
					blockBuffer[bytePosition] = circ[(head + bytePosition) % blockSize];
				blockDataCopied = true;
			}
			if (!checksumMatches(meta.blockTable, blockIndex, meta.rsumLen, meta.checksumLen, stride, blockBuffer))
				continue;
			srcOff[blockIndex] = cast(long) windowStart;
			matched++;
		}
	}

	double scanSpan = (progressEnd - progressStart) * 0.9;
	enum SCAN_BUF_SIZE = 512 * 1024;
	ubyte[] scanBuf = new ubyte[](SCAN_BUF_SIZE);
	tryMatch(0);
	ulong scanOffset = 0;
	ulong scanLimit = dualWindow ? srcSize - blockSize : srcSize;
	outer: while (scanOffset + blockSize < scanLimit) {
		ulong remaining = scanLimit - blockSize - scanOffset;
		size_t toRead = remaining < SCAN_BUF_SIZE
			? cast(size_t) remaining : SCAN_BUF_SIZE;
		auto chunk = srcFile.rawRead(scanBuf[0 .. toRead]);
		if (chunk.length == 0)
			break;
		foreach (inputByte; chunk) {
			if (dualWindow) {
				// The byte leaving circ1 crosses into circ0 as its new incoming byte
				ubyte crossover = circ1[head];
				circ1[head] = inputByte;
				rsumRoll(r1, crossover, inputByte, blockSize);
				ubyte leaving0 = circ[head];
				circ[head] = crossover;
				rsumRoll(r, leaving0, crossover, blockSize);
			} else {
				ubyte leaving = circ[head];
				circ[head] = inputByte;
				rsumRoll(r, leaving, inputByte, blockSize);
			}
			head = cast(uint)((head + 1) % blockSize);
			scanOffset++;
			tryMatch(scanOffset);
			if (matched == meta.numBlocks)
				break outer;
		}
		progress = progressStart + (progressEnd - progressStart) * 0.1
			+ scanSpan * (
				cast(double) scanOffset / srcSize);
	}

	writeln("zsync: rolling scan matched ", matched, " / ", meta.numBlocks, " blocks total");
	progress = progressEnd;
	return srcOff;
}

// Assembles the target file at outputPath from matched source blocks and
// downloaded block ranges, advancing progress from progressStart to progressEnd
private bool assembleFile(
	ZsyncMeta meta,
	string existingPath,
	const(long[]) srcOff,
	string outputPath,
	ref double progress,
	double progressStart,
	double progressEnd,
	out string error,
	bool delegate() shouldCancel = null) {
	double span = progressEnd - progressStart;
	uint blockSize = meta.blocksize;

	// Coalesce unmatched blocks into byte ranges to minimize HTTP requests
	struct Range {
		ulong start, last;
	} // inclusive on both ends
	Range[] ranges;
	foreach (blockIndex; 0 .. meta.numBlocks) {
		if (srcOff[blockIndex] >= 0)
			continue;
		ulong rangeStart = cast(ulong) blockIndex * blockSize;
		ulong rangeEnd = min(rangeStart + blockSize, meta.length) - 1;
		if (ranges.length > 0 && ranges[$ - 1].last + 1 == rangeStart)
			ranges[$ - 1].last = rangeEnd;
		else
			ranges ~= Range(rangeStart, rangeEnd);
	}
	size_t unmatchedBlocks = 0;
	foreach (blockOffset; srcOff)
		if (blockOffset < 0)
			unmatchedBlocks++;
	writeln("zsync: ", ranges.length, " HTTP range request(s) needed, ", unmatchedBlocks, " unmatched blocks (~",
		unmatchedBlocks * meta.blocksize / 1024, " KiB to download)");

	// Download each range into a keyed map so assembly can seek by block index
	// rangeData maps range start byte → downloaded bytes for that range
	ubyte[][ulong] rangeData;
	foreach (rangeIndex, ref range; ranges) {
		auto rangeBody = appender!(ubyte[])();
		auto http = HTTP(meta.fileUrl);
		http.maxRedirects(MAX_HTTP_REDIRECTS);
		http.addRequestHeader(
			"Range",
			"bytes=" ~ range.start.to!string ~ "-" ~ range.last.to!string);
		http.onReceive = (ubyte[] chunk) {
			rangeBody.put(chunk);
			return chunk.length;
		};
		ulong rangeExpected = range.last - range.start + 1;
		http.onProgress = (size_t dlTotal, size_t dlNow, size_t ulTotal, size_t ulNow) {
			if (shouldCancel !is null && shouldCancel())
				return 1;
			// Use rangeBody bytes received as numerator because GitHub CDN
			// streams range responses without Content-Length, leaving dlTotal=0
			progress = progressStart + span
				* (rangeIndex + cast(
						double) rangeBody.data.length / rangeExpected)
				/ ranges.length;
			return 0;
		};
		if (shouldCancel !is null && shouldCancel()) {
			error = "cancelled";
			return false;
		}
		try {
			http.perform();
		} catch (CurlException curlError) {
			error = curlError.msg;
			return false;
		}
		immutable uint code = http.statusLine.code;
		// 200 means the server returned the full file (no range support)
		if (code != 200 && code != 206) {
			error = "HTTP " ~ code.to!string ~ " for range " ~ range.start.to!string;
			return false;
		}
		rangeData[range.start] = rangeBody.data;
		writeln("zsync: downloaded range ", rangeIndex + 1, "/", ranges.length, " bytes=", range.start, "-", range
				.last,
				" got=", rangeBody.data.length, "B");
		progress = progressStart
			+ span * (cast(double)(rangeIndex + 1) / ranges.length);
	}

	// Write output file sequentially, one block at a time
	auto outFile = File(outputPath, "wb");
	scope (exit)
		outFile.close();
	auto srcFile = (existingPath.length && exists(existingPath))
		? File(existingPath, "rb") : File.init;
	scope (exit)
		if (srcFile.isOpen)
			srcFile.close();

	foreach (blockIndex; 0 .. meta.numBlocks) {
		ulong blockStart = cast(ulong) blockIndex * blockSize;
		ulong blockLen = min(blockStart + blockSize, meta.length) - blockStart;
		if (srcOff[blockIndex] >= 0 && srcFile.isOpen) {
			ubyte[] blockData = new ubyte[](cast(size_t) blockLen);
			srcFile.seek(srcOff[blockIndex]);
			srcFile.rawRead(blockData);
			outFile.rawWrite(blockData);
		} else {
			// Find which range contains this block and extract the slice
			// Always equals blockStart
			ulong rngStart = (blockStart / blockSize) * blockSize;
			foreach (rStart, ref rBytes; rangeData) {
				if (rStart <= blockStart
					&& blockStart < rStart + rBytes.length) {
					size_t sliceOff = cast(size_t)(blockStart - rStart);
					size_t sliceLen = cast(size_t) blockLen;
					outFile.rawWrite(rBytes[sliceOff .. sliceOff + sliceLen]);
					break;
				}
			}
		}
	}

	return true;
}

// Downloads and applies a .zsync delta to produce a new AppImage at outputPath
// progress advances from progressStart to progressEnd
private bool applyZsync(
	ZsyncMeta meta,
	string existingPath,
	string outputPath,
	ref double progress,
	ref string progressText,
	double progressStart,
	double progressEnd,
	out string errorMessage,
	bool delegate() shouldCancel = null) {
	double span = progressEnd - progressStart;

	progressText = "update.zsync.status.matching";
	writeln("zsync: scanning for reusable blocks in ", existingPath.length ? existingPath : "(none)");
	auto srcOff = matchExistingBlocks(meta, existingPath,
		progress, progressStart, progressStart + 0.4 * span);
	size_t matchedCount = 0;
	foreach (blockOffset; srcOff)
		if (blockOffset >= 0)
			matchedCount++;
	writeln("zsync: ", matchedCount, " / ", meta.numBlocks, " blocks matched locally");
	progress = progressStart + 0.4 * span;

	progressText = "update.zsync.status.patching";
	if (!assembleFile(meta, existingPath, srcOff, outputPath, progress, progressStart + 0.4 * span, progressEnd,
			errorMessage, shouldCancel))
		return false;

	progress = progressEnd;
	return true;
}

// Fetches the .zsync metafile and checks the SHA-1 against the existing file
// Returns true on success, available=false means already up to date
public bool checkZsyncForUpdate(
	string appDirectory,
	string sanitizedName,
	string metaUrl,
	out bool available,
	out string error,
	bool delegate() shouldCancel = null) {
	available = true;

	InstallMethod installMethod;
	if (!readManifestFields(appDirectory, installMethod, error))
		return false;

	ubyte[] metaRaw;
	if (!fetchBytes(metaUrl, metaRaw, error, shouldCancel)) {
		error = "Could not fetch .zsync file: " ~ error;
		return false;
	}

	ZsyncMeta meta;
	if (!parseZsyncMeta(metaRaw, metaUrl, meta, error))
		return false;

	string existingPath;
	if (installMethod == InstallMethod.AppImage) {
		string candidate = buildPath(appDirectory, sanitizedName ~ ".AppImage");
		if (exists(candidate))
			existingPath = candidate;
	} else {
		string candidate = buildPath(appDirectory, APPLICATIONS_SUBDIR, sanitizedName ~ ".AppImage");
		if (exists(candidate))
			existingPath = candidate;
	}

	if (!existingPath.length) {
		writeln("zsync: check: no existing file, update available");
		return true;
	}

	string sha1Error;
	if (verifySha1(existingPath, meta.sha1, sha1Error)) {
		available = false;
		writeln("zsync: check: already up to date");
	} else {
		writeln("zsync: check: update available");
	}
	return true;
}

// Downloads the .zsync metafile, applies the delta, verifies and installs
// progress goes 0.0 to 1.0, progressText and wasUpdated report state to caller
public bool performZsyncUpdate(
	string appDirectory,
	string sanitizedName,
	string metaUrl,
	ref double progress,
	ref string progressText,
	out bool wasUpdated,
	out string errorMessage,
	bool delegate() shouldCancel = null,
	bool force = false) {
	progress = Progress.start;
	progressText = "update.zsync.status.start";
	wasUpdated = true;
	writeln("zsync: starting update for '", sanitizedName, "'");
	writeln("zsync: metaUrl = ", metaUrl);
	writeln("zsync: appDirectory = ", appDirectory);

	InstallMethod installMethod;
	if (!readManifestFields(appDirectory, installMethod, errorMessage)) {
		writeln("zsync: readManifestFields failed: ", errorMessage);
		return false;
	}
	writeln("zsync: installMethod = ", installMethod);

	progress = Progress.afterManifest;
	progressText = "update.zsync.status.fetching";
	writeln("zsync: fetching metafile from ", metaUrl);

	ubyte[] metaRaw;
	string fetchError;
	if (!fetchBytes(metaUrl, metaRaw, fetchError)) {
		errorMessage = "Could not fetch .zsync file: " ~ fetchError;
		writeln("zsync: fetch failed: ", errorMessage);
		return false;
	}
	writeln("zsync: fetched metafile, ", metaRaw.length, " bytes");

	ZsyncMeta meta;
	if (!parseZsyncMeta(metaRaw, metaUrl, meta, errorMessage)) {
		writeln("zsync: parseZsyncMeta failed: ", errorMessage);
		return false;
	}
	writeln("zsync: meta parsed: blocksize=", meta.blocksize, " length=", meta.length,
		" numBlocks=", meta.numBlocks, " seqMatches=", meta.seqMatches,
		" rsumLen=", meta.rsumLen, " checksumLen=", meta.checksumLen);
	writeln("zsync: target file URL = ", meta.fileUrl);

	progress = Progress.afterMeta;

	// Location depends on install method, AppImage mode stores in appDir root
	// Extracted mode stores in the metadata subdir
	string existingPath;
	bool hadExistingAppImage;
	if (installMethod == InstallMethod.AppImage) {
		string candidate = buildPath(appDirectory, sanitizedName ~ ".AppImage");
		if (exists(candidate)) {
			existingPath = candidate;
			hadExistingAppImage = true;
		}
	} else {
		string candidate = buildPath(
			appDirectory, APPLICATIONS_SUBDIR, sanitizedName ~ ".AppImage");
		if (exists(candidate)) {
			existingPath = candidate;
			hadExistingAppImage = true;
		}
	}
	if (existingPath.length)
		writeln("zsync: reusing existing file: ", existingPath);
	else
		writeln("zsync: no existing AppImage found, all blocks will be downloaded");

	// If the existing file already matches the target SHA-1, nothing to do
	if (!force && existingPath.length) {
		string sha1CheckError;
		if (verifySha1(existingPath, meta.sha1, sha1CheckError)) {
			wasUpdated = false;
			progress = Progress.complete;
			writeln("zsync: already up to date");
			return true;
		}
	}

	// For AppImage mode place temp in the update subdir inside appDirectory
	// For Extracted mode place temp outside appDirectory so doInstallExtracted can wipe the dir freely
	string tempPath;
	if (installMethod == InstallMethod.AppImage) {
		string updateDir = buildPath(
			appDirectory, APPLICATIONS_SUBDIR, UPDATE_SUBDIR);
		try {
			mkdirRecurse(updateDir);
		} catch (FileException error) {
			errorMessage = "Could not create update directory: " ~ error.msg;
			return false;
		}
		tempPath = buildPath(updateDir, sanitizedName ~ ".AppImage");
	} else {
		tempPath = buildPath(
			dirName(appDirectory), "." ~ sanitizedName ~ ".update.AppImage");
	}
	writeln("zsync: output temp path = ", tempPath);

	scope (failure) {
		if (exists(tempPath))
			try {
				remove(tempPath);
			} catch (FileException) {
			}
	}

	if (!applyZsync(meta, existingPath, tempPath,
			progress, progressText,
			Progress.afterMeta, Progress.afterDownload,
			errorMessage, shouldCancel)) {
		writeln("zsync: applyZsync failed: ", errorMessage);
		return false;
	}
	writeln("zsync: applyZsync complete, verifying SHA-1");

	string sha1Error;
	if (!verifySha1(tempPath, meta.sha1, sha1Error)) {
		errorMessage = sha1Error;
		writeln("zsync: SHA-1 verification failed: ", errorMessage);
		return false;
	}

	writeln("zsync: SHA-1 verified, proceeding to install");
	if (!finishInstall(
			tempPath, appDirectory, sanitizedName,
			installMethod,
			progress, Progress.afterDownload, Progress.complete,
			progressText,
			"update.zsync.status.installing",
			"update.zsync.status.extracting",
			errorMessage, false, shouldCancel))
		return false;

	// For Extracted mode when no prior AppImage existed in the metadata dir,
	// the user chose download+extract+cleanup so we remove the placed AppImage
	if (installMethod == InstallMethod.Extracted && !hadExistingAppImage) {
		string placed = buildPath(
			appDirectory, APPLICATIONS_SUBDIR, sanitizedName ~ ".AppImage");
		if (exists(placed)) {
			try {
				remove(placed);
				writeln("zsync: removed AppImage from metadata dir (no prior AppImage)");
			} catch (FileException error) {
				writeln(
					"zsync: warning: could not remove AppImage from metadata dir: ",
					error.msg);
			}
		}
	}
	return true;
}
