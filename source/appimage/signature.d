// GPG signature verification for AppImage .sha256_sig ELF section
// The section holds a PGP detached signature over the SHA-256 digest of all preceding file bytes
module appimage.signature;

import std.file : FileException, write, remove;
import std.exception : collectException;
import std.path : buildPath;
import std.process : execute, ProcessException;
import std.stdio : File, writeln;
import std.digest.sha : SHA256;
import std.digest : digest;

// Result of a signature check on a downloaded AppImage
public enum SignatureStatus {
	// No .sha256_sig section found — file is unsigned
	None,
	// Signature present and gpg confirmed it as valid
	Verified,
	// Signature present, gpg ran, but it reported an invalid signature
	Invalid,
	// Signature present but the signer's key is not in the user's keyring
	Unverifiable,
	// Signature present but gpg is not installed
	GpgMissing,
}

// Holds the outcome and signer key ID from a GPG signature check
public struct SignatureResult {
	SignatureStatus status;
	string keyId;
}

// Checks the GPG signature in the .sha256_sig section at sigOffset for sigSize bytes.
// Returns None when sigOffset is 0 meaning no signature section was found.
public SignatureResult checkSignature(string filePath, ulong sigOffset, ulong sigSize) {
	if (sigOffset == 0 || sigSize == 0)
		return SignatureResult(SignatureStatus.None, "");

	// 1. Extract signature bytes from file
	ubyte[] sigBytes;
	try {
		auto f = File(filePath, "rb");
		scope (exit)
			f.close();
		f.seek(cast(long) sigOffset);
		sigBytes = new ubyte[](sigSize);
		auto read = f.rawRead(sigBytes);
		if (read.length < sigSize) {
			writeln("signature: could not read sig section");
			return SignatureResult(SignatureStatus.Unverifiable, "");
		}
	} catch (FileException error) {
		writeln("signature: could not read sig section: ", error.msg);
		return SignatureResult(SignatureStatus.Unverifiable, "");
	}

	// If the section is present but contains no valid PGP data, treat as unsigned.
	// Binary PGP packets have bit 7 set; armored PGP starts with "-----BEGIN PGP".
	bool isBinaryPgp = sigBytes.length >= 1 && (sigBytes[0] & 0x80) != 0;
	bool isArmoredPgp = sigBytes.length >= 10
		&& sigBytes[0 .. 10] == cast(ubyte[]) "-----BEGIN";
	if (!isBinaryPgp && !isArmoredPgp)
		return SignatureResult(SignatureStatus.None, "");

	// 2. Compute SHA-256 of file[0..sigOffset]
	ubyte[32] hashDigest;
	try {
		auto sha = SHA256();
		auto f = File(filePath, "rb");
		scope (exit)
			f.close();

		enum size_t BUF_SIZE = 65_536;
		ubyte[BUF_SIZE] buf;
		ulong remaining = sigOffset;
		while (remaining > 0) {
			size_t want = remaining < BUF_SIZE ? cast(size_t) remaining : BUF_SIZE;
			auto chunk = f.rawRead(buf[0 .. want]);
			if (chunk.length == 0)
				break;
			sha.put(chunk);
			remaining -= chunk.length;
		}
		hashDigest = sha.finish();
	} catch (FileException error) {
		writeln("signature: could not compute SHA-256: ", error.msg);
		return SignatureResult(SignatureStatus.Unverifiable, "");
	}

	// 3. Write both to temp files and run gpg --verify
	import std.conv : to;
	import core.sys.posix.unistd : getpid;
	import constants : SIGNATURE_TEMP_FILE_PREFIX, TEMP_DIRECTORY_PATH;

	string pid = getpid().to!string;
	string sigPath = buildPath(
		TEMP_DIRECTORY_PATH,
		SIGNATURE_TEMP_FILE_PREFIX ~ pid ~ ".sig");
	string hashPath = buildPath(
		TEMP_DIRECTORY_PATH,
		SIGNATURE_TEMP_FILE_PREFIX ~ pid ~ ".hash");

	scope (exit) {
		collectException(remove(sigPath));
		collectException(remove(hashPath));
	}

	try {
		write(sigPath, sigBytes);
		write(hashPath, hashDigest[]);
	} catch (FileException error) {
		writeln("signature: could not write temp files: ", error.msg);
		return SignatureResult(SignatureStatus.Unverifiable, "");
	}

	try {
		// --status-fd 1 gives machine-parseable status lines on stdout
		auto result = execute([
			"gpg", "--status-fd", "1", "--verify", sigPath, hashPath
		]);
		writeln("signature: gpg exit=", result.status,
			" output=", result.output);
		string keyId = parseGpgKeyId(result.output);
		// Fall back to the binary PGP parser when gpg didn't send an ERRSIG line
		if (keyId.length == 0)
			keyId = extractSigKeyId(sigBytes);
		if (result.status == 0)
			return SignatureResult(SignatureStatus.Verified, keyId);
		// exit 1 = gpg confirmed the signature is bad (tampered/corrupt)
		// exit 2 = gpg could not check (key not in keyring, etc.)
		if (result.status == 1)
			return SignatureResult(SignatureStatus.Invalid, keyId);
		return SignatureResult(SignatureStatus.Unverifiable, keyId);
	} catch (ProcessException error) {
		writeln("signature: gpg not available: ", error.msg);
		// gpg not installed, try binary PGP parser as fallback
		string fallbackKeyId = extractSigKeyId(sigBytes);
		return SignatureResult(SignatureStatus.GpgMissing, fallbackKeyId);
	}
}

// Extracts the signing key ID from gpg --status-fd output.
// Looks for ERRSIG, GOODSIG, or BADSIG status lines that carry the key ID.
private string parseGpgKeyId(string output) {
	import std.string : indexOf;

	foreach (tag; [
			"[GNUPG:] ERRSIG ",
			"[GNUPG:] GOODSIG ",
			"[GNUPG:] BADSIG "
		]) {
		ptrdiff_t pos = indexOf(output, tag);
		if (pos < 0)
			continue;
		size_t start = cast(size_t) pos + tag.length;
		size_t end = start;
		while (end < output.length
			&& output[end] != ' '
			&& output[end] != '\n'
			&& output[end] != '\r')
			end++;
		if (end > start)
			return output[start .. end];
	}
	return "";
}

// Extracts the issuer key ID from a PGP binary signature packet.
// Checks subpacket type 33 for modern gpg 2.2 and type 16 for older versions.
private string extractSigKeyId(const(ubyte)[] data) {
	import std.format : format;

	if (data.length < 3 || !(data[0] & 0x80))
		return "";

	// Parse packet header to find where the body starts
	size_t bodyOffset;
	if (data[0] & 0x40) {
		// New format (e.g. 0xC2 for signature): length starts at byte 1
		if (data.length < 2)
			return "";
		ubyte lengthByte = data[1];
		if (lengthByte < 192)
			bodyOffset = 2;
		else if (lengthByte < 224 && data.length >= 3)
			bodyOffset = 3;
		else if (lengthByte == 255 && data.length >= 6)
			bodyOffset = 6;
		else
			return "";
	} else {
		// Old format: length type in bits 1-0 of tag byte
		ubyte lengthType = data[0] & 3;
		if (lengthType == 0)
			bodyOffset = 2;
		else if (lengthType == 1)
			bodyOffset = 3;
		else if (lengthType == 2)
			bodyOffset = 5;
		else
			return "";
	}

	if (bodyOffset >= data.length)
		return "";
	const(ubyte)[] body = data[bodyOffset .. $];

	// Only handle version 4 signature packets
	if (body.length < 6 || body[0] != 4)
		return "";

	// Walk a subpacket region; return key ID hex on first match
	string scanForKeyId(const(ubyte)[] sp) {
		import std.format : format;

		size_t i = 0;
		while (i < sp.length) {
			ubyte flagByte = sp[i];
			size_t byteLength;
			size_t typeOffset;
			if (flagByte < 192) {
				byteLength = flagByte;
				typeOffset = i + 1;
				i += 1 + byteLength;
			} else if (flagByte < 224 && i + 1 < sp.length) {
				byteLength =
					((cast(size_t)(flagByte - 192)) << 8) + sp[i + 1] + 192;
				typeOffset = i + 2;
				i += 2 + byteLength;
			} else {
				break;
			}
			if (byteLength == 0 || typeOffset >= sp.length)
				continue;
			ubyte subpacketType = sp[typeOffset];
			size_t dataOffset = typeOffset + 1;
			size_t dataLength = byteLength >= 1 ? byteLength - 1 : 0;
			// Type 33: Issuer Fingerprint (modern gpg, hashed subpackets)
			if (subpacketType == 33
				&& dataLength >= 1
				&& dataOffset < sp.length) {
				ubyte keyVersion = sp[dataOffset];
				// v4 key: 1 version byte + 20 fingerprint bytes
				if (keyVersion == 4
					&& dataLength >= 21
					&& dataOffset + 21 <= sp.length) {
					auto keyIdBytes = sp[dataOffset + 13 .. dataOffset + 21];
					return format!"%02X%02X%02X%02X%02X%02X%02X%02X"(
						keyIdBytes[0], keyIdBytes[1], keyIdBytes[2], keyIdBytes[3],
						keyIdBytes[4], keyIdBytes[5], keyIdBytes[6], keyIdBytes[7]);
				}
				// v6 key: 1 version byte + 32 fingerprint bytes
				if (keyVersion == 6
					&& dataLength >= 33
					&& dataOffset + 33 <= sp.length) {
					auto keyIdBytes = sp[dataOffset + 1 .. dataOffset + 9];
					return format!"%02X%02X%02X%02X%02X%02X%02X%02X"(
						keyIdBytes[0], keyIdBytes[1], keyIdBytes[2], keyIdBytes[3],
						keyIdBytes[4], keyIdBytes[5], keyIdBytes[6], keyIdBytes[7]);
				}
			}
			// Type 16: Issuer Key ID (older gpg, unhashed subpackets)
			if (subpacketType == 16
				&& dataLength >= 8
				&& dataOffset + 8 <= sp.length) {
				auto keyIdBytes = sp[dataOffset .. dataOffset + 8];
				return format!"%02X%02X%02X%02X%02X%02X%02X%02X"(
					keyIdBytes[0], keyIdBytes[1], keyIdBytes[2], keyIdBytes[3],
					keyIdBytes[4], keyIdBytes[5], keyIdBytes[6], keyIdBytes[7]);
			}
		}
		return "";
	}

	// Hashed subpackets (modern gpg 2.2+ puts Issuer Fingerprint here)
	size_t hashedLen = (cast(size_t)
		body[4] << 8) | body[5];
	if (6 + hashedLen <= body.length) {
		auto keyId = scanForKeyId(body[6 .. 6 + hashedLen]);
		if (keyId.length)
			return keyId;
	}

	// Unhashed subpackets (older gpg puts Issuer Key ID here)
	size_t unhashedStart = 6 + hashedLen;
	if (unhashedStart + 2 <= body.length) {
		size_t unhashedLen = (cast(size_t)
			body[unhashedStart] << 8) | body[unhashedStart + 1];
		size_t unhashedOff = unhashedStart + 2;
		size_t unhashedEnd = unhashedOff + unhashedLen;
		if (unhashedEnd > body.length)
			unhashedEnd = body.length;
		return scanForKeyId(body[unhashedOff .. unhashedEnd]);
	}
	return "";
}
