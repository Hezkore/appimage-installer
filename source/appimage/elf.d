module appimage.elf;

import std.exception : ErrnoException;
import std.stdio : writeln, File;
import std.string : strip;

// AppImage type, architecture, and update method read from one ELF binary
public struct ElfInfo {
	ubyte appImageType; // 1 = ISO 9660 + ELF (legacy), 2 = ELF + squashfs
	string architecture; // e.g. "x86_64"
	string updateInfo; // Transport string from .upd_info section, or ""
	ulong sigSectionOffset; // File offset of .sha256_sig section content, 0 = absent
	ulong sigSectionSize; // Byte length of .sha256_sig section content
}

private ushort readLE16(const ubyte[] bytes, size_t offset) {
	return cast(ushort)(bytes[offset] | (bytes[offset + 1] << 8));
}

private uint readLE32(const ubyte[] bytes, size_t offset) {
	return bytes[offset] | (bytes[offset + 1] << 8) | (bytes[offset + 2] << 16) | (
		bytes[offset + 3] << 24);
}

private ulong readLE64(const ubyte[] bytes, size_t offset) {
	return readLE32(bytes, offset) | (cast(ulong) readLE32(bytes, offset + 4) << 32);
}

// Reads AppImage type, CPU architecture, and update info from the raw ELF binary
public ElfInfo readElfInfo(string filePath) {
	enum ubyte AI_0 = 0x41;
	enum ubyte AI_1 = 0x49;
	// The e_machine field values for architectures AppImages commonly target
	enum ushort EM_386 = 0x0003;
	enum ushort EM_X86_64 = 0x003E;
	enum ushort EM_ARM = 0x0028;
	enum ushort EM_AARCH64 = 0x00B7;
	// For Type 1, update info sits in the ISO 9660 PVD Application Use field
	enum size_t ISO_UPD_OFFSET = 33_651;
	enum size_t ISO_UPD_SIZE = 512;
	// ELF ident field byte positions and their sentinel values
	enum size_t ELF_HDR_SIZE = 64;
	enum size_t EI_CLASS = 4;
	enum ubyte ELF_CLASS_64 = 2;
	enum size_t EI_DATA = 5;
	enum ubyte ELF_LITTLE = 1;
	enum size_t AI_MARKER_0 = 8;
	enum size_t AI_MARKER_1 = 9;
	enum size_t AI_TYPE = 10;
	enum size_t ELF_MACHINE = 18;
	// 64-bit ELF header field offsets
	enum size_t E64_SHOFF = 40;
	enum size_t E64_SHENTSIZE = 58;
	enum size_t E64_SHNUM = 60;
	enum size_t E64_SHSTRNDX = 62;
	// 32-bit ELF header field offsets
	enum size_t E32_SHOFF = 32;
	enum size_t E32_SHENTSIZE = 46;
	enum size_t E32_SHNUM = 48;
	enum size_t E32_SHSTRNDX = 50;
	// 64-bit section header field offsets
	enum size_t SH64_NAME = 0;
	enum size_t SH64_OFFSET = 24;
	enum size_t SH64_SIZE = 32;
	// 32-bit section header field offsets
	enum size_t SH32_NAME = 0;
	enum size_t SH32_OFFSET = 16;
	enum size_t SH32_SIZE = 20;

	ElfInfo result;

	try {
		auto file = File(filePath, "rb");
		scope (exit)
			file.close();

		ubyte[ELF_HDR_SIZE] hdr;
		if (file.rawRead(hdr[]).length < ELF_HDR_SIZE)
			return result;
		if (hdr[0 .. 4] != [
				0x7F, cast(ubyte) 'E', cast(ubyte) 'L', cast(ubyte) 'F'
			])
			return result;
		// Only handling little-endian (EI_DATA == ELF_LITTLE) covers all mainstream Linux targets
		if (hdr[EI_DATA] != ELF_LITTLE)
			return result;

		bool is64 = hdr[EI_CLASS] == ELF_CLASS_64;

		if (hdr[AI_MARKER_0] == AI_0 && hdr[AI_MARKER_1] == AI_1)
			result.appImageType = hdr[AI_TYPE];

		switch (readLE16(hdr[], ELF_MACHINE)) {
		case EM_386:
			result.architecture = "i686";
			break;
		case EM_X86_64:
			result.architecture = "x86_64";
			break;
		case EM_ARM:
			result.architecture = "armhf";
			break;
		case EM_AARCH64:
			result.architecture = "aarch64";
			break;
		default:
			break;
		}

		if (result.appImageType == 1) {
			ubyte[ISO_UPD_SIZE] isoField;
			file.seek(ISO_UPD_OFFSET);
			file.rawRead(isoField[]);
			size_t end = 0;
			while (end < ISO_UPD_SIZE && isoField[end] != 0)
				end++;
			string info = (cast(char[]) isoField[0 .. end]).dup.strip();
			if (info.length > 0)
				result.updateInfo = info;
			return result;
		}

		if (result.appImageType != 2)
			return result;

		ulong shoff = is64
			? readLE64(hdr[], E64_SHOFF) : readLE32(hdr[], E32_SHOFF);
		ushort shentsize = is64
			? readLE16(hdr[], E64_SHENTSIZE) : readLE16(hdr[], E32_SHENTSIZE);
		ushort shnum = is64
			? readLE16(hdr[], E64_SHNUM) : readLE16(hdr[], E32_SHNUM);
		ushort shstrndx = is64
			? readLE16(hdr[], E64_SHSTRNDX) : readLE16(hdr[], E32_SHSTRNDX);

		if (shoff == 0 || shnum == 0 || shentsize == 0)
			return result;

		ubyte[] shdrs = new ubyte[](shentsize * shnum);
		file.seek(cast(long) shoff);
		if (file.rawRead(shdrs).length < shdrs.length)
			return result;

		// Read the section name string table (.shstrtab)
		size_t shstrBase = shstrndx * shentsize;
		ulong strTabOff = is64
			? readLE64(shdrs, shstrBase + SH64_OFFSET) : readLE32(shdrs, shstrBase + SH32_OFFSET);
		ulong strTabSize = is64
			? readLE64(shdrs, shstrBase + SH64_SIZE) : readLE32(shdrs, shstrBase + SH32_SIZE);

		ubyte[] shstrtab = new ubyte[](strTabSize);
		file.seek(cast(long) strTabOff);
		if (file.rawRead(shstrtab).length < shstrtab.length)
			return result;

		foreach (sectionIndex; 0 .. shnum) {
			size_t base = sectionIndex * shentsize;
			uint nameIndex = readLE32(shdrs, base + (is64 ? SH64_NAME : SH32_NAME));
			if (nameIndex >= shstrtab.length)
				continue;

			size_t nameEnd = nameIndex;
			while (nameEnd < shstrtab.length && shstrtab[nameEnd] != 0)
				nameEnd++;
			string sectionName = cast(string)(cast(char[]) shstrtab[nameIndex .. nameEnd]).dup;

			ulong secOff = is64
				? readLE64(shdrs, base + SH64_OFFSET) : readLE32(shdrs, base + SH32_OFFSET);
			ulong secSize = is64
				? readLE64(shdrs, base + SH64_SIZE) : readLE32(shdrs, base + SH32_SIZE);

			if (sectionName == ".upd_info") {
				if (secOff != 0 && secSize != 0) {
					ubyte[] content = new ubyte[](secSize);
					file.seek(cast(long) secOff);
					file.rawRead(content);

					size_t end = 0;
					while (end < content.length && content[end] != 0)
						end++;
					string info = (cast(char[]) content[0 .. end]).dup.strip();
					if (info.length > 0)
						result.updateInfo = info;
				}
			} else if (sectionName == ".sha256_sig") {
				if (secOff != 0 && secSize != 0) {
					result.sigSectionOffset = secOff;
					result.sigSectionSize = secSize;
				}
			}

			// Stop scanning once both sections have been found
			if (result.updateInfo.length && result.sigSectionOffset != 0)
				break;
		}
	} catch (ErrnoException error) {
		writeln("Failed to read ELF info: ", error.msg);
	}

	return result;
}
