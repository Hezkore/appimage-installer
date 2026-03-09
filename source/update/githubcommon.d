// Shared GitHub API release-fetch logic used by gh-releases-zsync and gh-releases
module update.githubcommon;

import std.conv : to;
import std.json : JSONException, JSONType, JSONValue, parseJSON;
import std.net.curl : CurlException, HTTP;
import std.stdio : writeln;

import apputils : readConfigGithubToken;
import constants : INSTALLER_NAME, TAG_LATEST, TAG_LATEST_PRE, TAG_LATEST_ALL,
	HTTP_FORBIDDEN, HTTP_TOO_MANY_REQUESTS, HTTP_BAD_REQUEST;

package enum string GITHUB_API_BASE = "https://api.github.com/repos/";

// Fetches the GitHub release JSON for ownerName/repositoryName
// Returns false and sets error on network or parse failure
public bool fetchGitHubRelease(
	string ownerName,
	string repositoryName,
	string tag,
	out JSONValue releaseJson,
	out string error,
	bool delegate() shouldCancel = null) {
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
