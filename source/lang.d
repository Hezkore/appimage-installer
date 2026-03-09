// String table with runtime language switching
// All languages are embedded at compile time to avoid runtime file path issues
//
module lang;

import std.string : strip, indexOf, splitLines, replace;
import std.conv : to;

private immutable string EN_CONF = import("en.conf");
private immutable string SV_CONF = import("sv.conf");

private __gshared string[string][string] allStrings;
private __gshared string[string] strings;
private __gshared string activeLang = "en";

private string[string] parseLang(string rawContent) {
	string[string] parsed;
	string lastKey;
	foreach (line; rawContent.splitLines()) {
		string entry = line.strip();
		if (!entry.length) {
			lastKey = "";
			continue;
		}
		if (entry[0] == '#') {
			lastKey = "";
			continue;
		}
		auto eq = entry.indexOf('=');
		if (eq < 1) {
			if (lastKey.length)
				parsed[lastKey] ~= "\n" ~ entry.replace("\\n", "\n");
			continue;
		}
		lastKey = entry[0 .. eq].strip();
		parsed[lastKey] = entry[eq + 1 .. $].replace("\\n", "\n");
	}
	return parsed;
}

shared static this() {
	allStrings["en"] = parseLang(EN_CONF);
	allStrings["sv"] = parseLang(SV_CONF);
	strings = allStrings["en"];
}

// Returns the display name for a locale code
string langName(string locale) {
	switch (locale) {
	case "en":
		return "English";
	case "sv":
		return "Svenska";
	default:
		return locale;
	}
}

// Returns all available locale codes
string[] availableLangs() {
	return ["en", "sv"];
}

// Returns the active locale code
string activeLangCode() {
	return activeLang;
}

// Switches to a different language by reloading the string table
void setLang(string locale) {
	auto table = locale in allStrings;
	if (table is null)
		return;
	strings = *table;
	activeLang = locale;
}

// Returns the localized string for key in a specific locale without changing the active lang
string translateIn(Args...)(string locale, string key, Args args) {
	auto table = locale in allStrings;
	string value = (table && key in *table) ? (*table)[key] : key;
	static foreach (i, _; Args)
		value = value.replace("{" ~ to!string(i + 1) ~ "}", to!string(args[i]));
	return value;
}

// Returns the localized string for key, substituting {1}, {2} etc with extra args
string L(Args...)(string key, Args args) {
	string value = (key in strings) ? strings[key] : key;
	static foreach (i, _; Args)
		value = value.replace("{" ~ to!string(i + 1) ~ "}", to!string(args[i]));
	return value;
}
