// Shared GitHub API release-fetch logic used by gh-releases-zsync and gh-releases
module update.githubcommon;

import core.sync.mutex : Mutex;
import core.time : MonoTime, minutes;
import std.conv : to;
import std.json : JSONException, JSONType, JSONValue, parseJSON;
import std.net.curl : CurlException, HTTP;
import std.path : globMatch;
import std.regex : matchAll, regex;
import std.stdio : writeln;

import apputils : readConfigGithubToken;
import constants : HOST_ARCHITECTURE, INSTALLER_NAME, TAG_LATEST, TAG_LATEST_PRE, TAG_LATEST_ALL,
	HTTP_FORBIDDEN, HTTP_TOO_MANY_REQUESTS, HTTP_BAD_REQUEST;

// Architecture names used in release asset filenames, for each name the ELF reader reports
private immutable string[][string] ASSET_ARCH_NAMES = [
	"x86_64": ["x86_64", "amd64", "x64"],
	"aarch64": ["aarch64", "arm64"],
	"armhf": ["armhf", "armv7l", "armv7"],
	"i686": ["i686", "i386"],
];

// True when name matches pattern and does not name an architecture other than this machine's
// Release patterns like "App-*.AppImage" also match the arm64 build of the same release
public bool assetMatchesHost(string name, string pattern) {
	import std.algorithm : canFind;
	import std.uni : toLower;

	if (!globMatch(name, pattern))
		return false;
	auto archNamePattern = regex(
		`(?:^|[-._ ])(x86_64|amd64|x64|aarch64|arm64|armhf|armv7l|armv7|i686|i386)(?=[-._ ]|$)`, "i");
	auto hostNames = HOST_ARCHITECTURE in ASSET_ARCH_NAMES;
	foreach (found; matchAll(name, archNamePattern)) {
		if (hostNames is null || !(*hostNames).canFind(found[1].toLower))
			return false;
	}
	return true;
}

package enum string GITHUB_API_BASE = "https://api.github.com/repos/";

// How long a fetched release is reused, so a check followed by an update
// costs one API request instead of several against the unauthenticated limit
private enum RELEASE_CACHE_LIFETIME = 10.minutes;

private struct CachedRelease {
	JSONValue releaseJson;
	MonoTime fetchedAt;
}

// Shared across threads because checks run on worker threads
private __gshared CachedRelease[string] releaseCache;
private __gshared Mutex releaseCacheLock;

shared static this() {
	releaseCacheLock = new Mutex;
}

// Fetches the GitHub release JSON for ownerName/repositoryName
// Reuses a response fetched within RELEASE_CACHE_LIFETIME
// Returns false and sets error on network or parse failure
public bool fetchGitHubRelease(
	string ownerName,
	string repositoryName,
	string tag,
	out JSONValue releaseJson,
	out string error,
	bool delegate() shouldCancel = null) {
	string cacheKey = ownerName ~ "/" ~ repositoryName ~ "@" ~ tag;
	synchronized (releaseCacheLock) {
		if (auto cached = cacheKey in releaseCache) {
			if (MonoTime.currTime - cached.fetchedAt < RELEASE_CACHE_LIFETIME) {
				writeln("ghcommon: reusing cached release for ", cacheKey);
				releaseJson = cached.releaseJson;
				return true;
			}
		}
	}
	if (!fetchGitHubReleaseFromApi(
			ownerName, repositoryName, tag, releaseJson, error, shouldCancel))
		return false;
	synchronized (releaseCacheLock)
		releaseCache[cacheKey] = CachedRelease(releaseJson, MonoTime.currTime);
	return true;
}

// Requests the release JSON from the GitHub API without the cache
private bool fetchGitHubReleaseFromApi(
	string ownerName,
	string repositoryName,
	string tag,
	out JSONValue releaseJson,
	out string error,
	bool delegate() shouldCancel) {
	if (tag == TAG_LATEST_PRE || tag == TAG_LATEST_ALL) {
		string apiUrl = GITHUB_API_BASE ~ ownerName ~ "/"
			~ repositoryName ~ "/releases?per_page=50";
		writeln("ghcommon: listing releases via ", apiUrl);
		string body;
		int statusCode;
		try {
			auto http = HTTP(apiUrl);
			http.addRequestHeader("User-Agent", INSTALLER_NAME);
			http.addRequestHeader("Accept", "application/vnd.github+json");
			string gitHubToken = readConfigGithubToken();
			if (gitHubToken.length)
				http.addRequestHeader(
					"Authorization", "Bearer " ~ gitHubToken);
			http.onReceive = (ubyte[] data) {
				body ~= cast(string) data;
				return data.length;
			};
			http.onReceiveStatusLine = (HTTP.StatusLine sl) {
				statusCode = sl.code;
			};
			if (shouldCancel !is null)
				http.onProgress = (ulong dlTotal, ulong dlNow, ulong ulTotal, ulong ulNow) {
				return shouldCancel() ? 1 : 0;
			};
			http.perform();
		} catch (CurlException curlException) {
			error = "GitHub API request failed: " ~ curlException.msg;
			return false;
		}
		if (statusCode == HTTP_FORBIDDEN || statusCode == HTTP_TOO_MANY_REQUESTS) {
			error = "GitHub API rate limited (HTTP " ~ statusCode.to!string ~ ")";
			return false;
		}
		if (statusCode >= HTTP_BAD_REQUEST) {
			error = "GitHub API error HTTP " ~ statusCode.to!string;
			return false;
		}
		JSONValue list;
		try {
			list = parseJSON(body);
		} catch (JSONException jsonException) {
			error = "GitHub API response parse failed: " ~ jsonException.msg;
			return false;
		}
		if (list.type != JSONType.array || list.array.length == 0) {
			error = "No releases found for " ~ ownerName
				~ "/" ~ repositoryName;
			return false;
		}
		if (tag == TAG_LATEST_ALL) {
			releaseJson = list.array[0];
			return true;
		}
		foreach (release; list.array) {
			auto ptr = "prerelease" in release;
			if (ptr && ptr.type == JSONType.true_) {
				releaseJson = release;
				return true;
			}
		}
		error = "No pre-release found for " ~ ownerName
			~ "/" ~ repositoryName;
		return false;
	}
	string apiUrl = GITHUB_API_BASE ~ ownerName ~ "/" ~ repositoryName;
	apiUrl ~= (tag == TAG_LATEST) ? "/releases/latest" : "/releases/tags/" ~ tag;
	writeln("ghcommon: fetching release via ", apiUrl);
	string body;
	int statusCode;
	try {
		auto http = HTTP(apiUrl);
		http.addRequestHeader("User-Agent", INSTALLER_NAME);
		http.addRequestHeader("Accept", "application/vnd.github+json");
		string gitHubToken = readConfigGithubToken();
		if (gitHubToken.length)
			http.addRequestHeader("Authorization", "Bearer " ~ gitHubToken);
		http.onReceive = (ubyte[] data) {
			body ~= cast(string) data;
			return data.length;
		};
		http.onReceiveStatusLine = (HTTP.StatusLine sl) { statusCode = sl.code; };
		if (shouldCancel !is null)
			http.onProgress = (ulong dlTotal, ulong dlNow, ulong ulTotal, ulong ulNow) {
			return shouldCancel() ? 1 : 0;
		};
		http.perform();
	} catch (CurlException curlException) {
		error = "GitHub API request failed: " ~ curlException.msg;
		return false;
	}
	if (statusCode == HTTP_FORBIDDEN || statusCode == HTTP_TOO_MANY_REQUESTS) {
		error = "GitHub API rate limited (HTTP " ~ statusCode.to!string ~ ")";
		return false;
	}
	if (statusCode >= HTTP_BAD_REQUEST) {
		error = "GitHub API error HTTP " ~ statusCode.to!string;
		return false;
	}
	try {
		releaseJson = parseJSON(body);
	} catch (JSONException jsonException) {
		error = "GitHub API response parse failed: " ~ jsonException.msg;
		return false;
	}
	return true;
}
