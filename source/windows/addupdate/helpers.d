module windows.addupdate.helpers;

import std.file : FileException;
import std.path : buildPath;
import std.string : endsWith, indexOf, lastIndexOf, startsWith, strip;
import std.stdio : writeln;

import gtk.box : Box;
import gtk.button : Button;
import gtk.entry : Entry;
import gtk.image : Image;
import gtk.label : Label;
import gtk.revealer : Revealer;
import gtk.types : Align, Orientation;

import windows.base : revealAfterDelay;
import windows.base : CONTENT_REVEAL_DELAY_MS, ACTION_REVEAL_DELAY_MS;
import windows.base : makeIcon, setIconNames;
import constants : APPLICATIONS_SUBDIR, MANIFEST_FILE_NAME;
import appimage.manifest : Manifest;
import apputils : xdgDataHome, installBaseDir;
import lang : L;

// The update method types the wizard can configure
public enum MethodKind {
	GitHubZsync,
	GitHubRelease,
	GitHubLinuxManifest,
	Zsync,
	Pling,
	DirectLink
}

public enum int TEST_MIN_MS = 1500;

// Pixel measurements for the update method choice row content
private enum Layout {
	iconSize = 32,
	iconMarginEnd = 14,
	textColumnSpacing = 3,
	rowPadding = 14,
}

// Strips the host prefix and anything after "owner/repository"
// Accepts bare "owner/repository", github.com URLs, and release URLs
public string normalizeGitHubInput(string s) {
	s = s.strip();
	foreach (prefix; [
			"https://github.com/", "http://github.com/", "github.com/"
		]) {
		if (s.startsWith(prefix))
			s = s[prefix.length .. $];
	}
	// Keep only the first two path segments and drop anything after
	auto firstSlash = s.indexOf('/');
	if (firstSlash > 0) {
		auto secondSlash = s.indexOf('/', firstSlash + 1);
		if (secondSlash > firstSlash)
			s = s[0 .. secondSlash];
	}
	return s;
}

// True when GitHub input looks like "owner/repository" or a GitHub URL
public bool isValidGitHub(string s) {
	s = normalizeGitHubInput(s);
	auto slashPosition = s.indexOf('/');
	return slashPosition > 0 && slashPosition < cast(ptrdiff_t) s.length - 1;
}

// True when zsync input is a valid http(s) URL ending in .zsync
public bool isValidZsync(string s) {
	s = s.strip();
	return (s.startsWith("http://") || s.startsWith("https://"))
		&& s.endsWith(".zsync");
}

// True when Pling input is a numeric product ID or a full Pling/KDE Store product URL
public bool isValidPling(string s) {
	import std.algorithm : all;
	import std.ascii : isDigit;

	s = s.strip();
	if (!s.length)
		return false;
	if (s.startsWith("http://") || s.startsWith("https://"))
		return s.indexOf("/p/") >= 0;
	return s.all!isDigit;
}

// Extracts the numeric product ID from a full Pling URL or returns the input unchanged
private string extractPlingProductId(string raw) {
	if (raw.startsWith("http://") || raw.startsWith("https://")) {
		auto lastSlash = raw.lastIndexOf('/');
		if (lastSlash >= 0 && lastSlash < cast(ptrdiff_t) raw.length - 1)
			return raw[lastSlash + 1 .. $];
	}
	return raw;
}

// True when direct link input is a valid http(s) URL
public bool isValidDirect(string s) {
	s = s.strip();
	return s.startsWith("http://") || s.startsWith("https://");
}

// True when a filename pattern is non-empty
public bool isValidPattern(string s) {
	return s.strip().length > 0;
}

// Builds the updateInfo string for the given method from raw input
// For GitHubRelease, raw is "owner/repository" and pattern is the wildcard filename string
public string buildUpdateInfo(MethodKind kind, string raw, string pattern = "") {
	raw = normalizeGitHubInput(raw);
	final switch (kind) {
	case MethodKind.GitHubZsync:
		auto slashPosition = raw.indexOf('/');
		return "gh-releases-zsync|"
			~ raw[0 .. slashPosition] ~ "|" ~ raw[slashPosition + 1 .. $]
			~ "|latest|*-x86_64.AppImage.zsync";
	case MethodKind.GitHubRelease:
		auto slashPosition = raw.indexOf('/');
		return "gh-releases|"
			~ raw[0 .. slashPosition] ~ "|" ~ raw[slashPosition + 1 .. $]
			~ "|latest|" ~ pattern.strip();
	case MethodKind.GitHubLinuxManifest:
		auto slashPosition = raw.indexOf('/');
		return "gh-linux-yml|"
			~ raw[0 .. slashPosition] ~ "|" ~ raw[slashPosition + 1 .. $];
	case MethodKind.Zsync:
		return "zsync|" ~ raw;
	case MethodKind.Pling:
		return "pling-v1-zsync|" ~ extractPlingProductId(raw);
	case MethodKind.DirectLink:
		return "direct-link|" ~ raw;
	}
}

// Writes updateInfo into the manifest.json for the given sanitizedName Throws FileException on failure
public void saveUpdateInfo(string sanitizedName, string updateInfo) {
	string appDir = buildPath(installBaseDir(), sanitizedName);
	string manifestPath = Manifest.pathFor(appDir);
	auto installedAppManifest = Manifest.load(manifestPath);
	if (installedAppManifest is null)
		throw new FileException(manifestPath,
			"No manifest.json for " ~ sanitizedName);
	installedAppManifest.updateInfo = updateInfo;
	installedAppManifest.save();
	writeln(
		"addupdate: saved updateInfo '", updateInfo, "' for '", sanitizedName, "'");
}

// Builds one activatable row in the method choice list
public Box makeChoiceRowContent(string iconName, string name, string subtitle) {
	return makeChoiceRowContent([iconName], name, subtitle);
}

// Falls back through names so the row still gets an icon on themes without every icon
public Box makeChoiceRowContent(string[] iconNames, string name, string subtitle) {
	auto icon = makeIcon(iconNames);
	icon.pixelSize = Layout.iconSize;
	icon.setValign(Align.Center);
	icon.setMarginEnd(Layout.iconMarginEnd);

	auto nameLabel = new Label(name);
	nameLabel.addCssClass("heading");
	nameLabel.setHalign(Align.Start);

	auto subtitleLabel = new Label(subtitle);
	subtitleLabel.setHalign(Align.Start);
	subtitleLabel.addCssClass("caption");
	subtitleLabel.addCssClass("dim-label");

	auto textColumn = new Box(Orientation.Vertical, Layout.textColumnSpacing);
	textColumn.setValign(Align.Center);
	textColumn.setHexpand(true);
	textColumn.append(nameLabel);
	textColumn.append(subtitleLabel);

	auto chevronIcon = Image.newFromIconName("go-next-symbolic");
	chevronIcon.setValign(Align.Center);
	chevronIcon.addCssClass("dim-label");

	auto rowBox = new Box(Orientation.Horizontal, 0);
	rowBox.setMarginTop(Layout.rowPadding);
	rowBox.setMarginBottom(Layout.rowPadding);
	rowBox.setMarginStart(Layout.rowPadding);
	rowBox.setMarginEnd(Layout.rowPadding);
	rowBox.append(icon);
	rowBox.append(textColumn);
	rowBox.append(chevronIcon);
	return rowBox;
}

// Fills in the input page widgets for the chosen method and resets for a clean entry animation
public void setupInputPage(
	MethodKind kind,
	ref MethodKind currentMethod,
	ref bool function(string) currentValidator,
	Image inputIcon,
	Label inputTitleLabel,
	Label inputDescriptionLabel,
	Label inputExampleLabel,
	Entry inputEntry,
	Button nextButton,
	Revealer inputEntryRev,
	Revealer nextButtonRevealer) {
	currentMethod = kind;

	final switch (kind) {
	case MethodKind.GitHubZsync:
		setIconNames(inputIcon, [
				"software-update-available-symbolic",
				"system-software-update-symbolic",
			]);
		inputTitleLabel.setLabel(L("addupdate.method.github"));
		inputDescriptionLabel.setLabel(L("addupdate.github.description"));
		inputExampleLabel.setLabel(L("addupdate.github.example"));
		inputEntry.setPlaceholderText(L("addupdate.github.placeholder"));
		currentValidator = &isValidGitHub;
		break;

	case MethodKind.GitHubRelease:
		setIconNames(inputIcon, [
				"software-update-available-symbolic",
				"system-software-update-symbolic",
			]);
		inputTitleLabel.setLabel(L("addupdate.method.github"));
		inputDescriptionLabel.setLabel(L("addupdate.ghrelease.pattern.description"));
		inputExampleLabel.setLabel(L("addupdate.ghrelease.pattern.example"));
		inputEntry.setPlaceholderText(L("addupdate.ghrelease.pattern.placeholder"));
		currentValidator = &isValidPattern;
		break;

	case MethodKind.GitHubLinuxManifest:
		setIconNames(inputIcon, [
				"software-update-available-symbolic",
				"system-software-update-symbolic",
			]);
		inputTitleLabel.setLabel(L("addupdate.method.github"));
		inputDescriptionLabel.setLabel(L("addupdate.github.description"));
		inputExampleLabel.setLabel(L("addupdate.github.example"));
		inputEntry.setPlaceholderText(L("addupdate.github.placeholder"));
		currentValidator = &isValidGitHub;
		break;

	case MethodKind.Zsync:
		setIconNames(inputIcon, [
				"emblem-synchronizing-symbolic",
				"network-transmit-receive-symbolic",
			]);
		inputTitleLabel.setLabel(L("addupdate.method.zsync"));
		inputDescriptionLabel.setLabel(L("addupdate.zsync.description"));
		inputExampleLabel.setLabel(L("addupdate.zsync.example"));
		inputEntry.setPlaceholderText(L("addupdate.zsync.placeholder"));
		currentValidator = &isValidZsync;
		break;

	case MethodKind.Pling:
		setIconNames(inputIcon, [
				"web-browser-symbolic",
				"network-workgroup-symbolic",
			]);
		inputTitleLabel.setLabel(L("addupdate.method.pling"));
		inputDescriptionLabel.setLabel(L("addupdate.pling.description"));
		inputExampleLabel.setLabel(L("addupdate.pling.example"));
		inputEntry.setPlaceholderText(L("addupdate.pling.placeholder"));
		currentValidator = &isValidPling;
		break;

	case MethodKind.DirectLink:
		setIconNames(inputIcon, ["folder-download-symbolic", "folder-symbolic"]);
		inputTitleLabel.setLabel(L("addupdate.method.direct"));
		inputDescriptionLabel.setLabel(L("addupdate.direct.description"));
		inputExampleLabel.setLabel(L("addupdate.direct.example"));
		inputEntry.setPlaceholderText(L("addupdate.direct.placeholder"));
		currentValidator = &isValidDirect;
		break;
	}

	inputEntry.setText("");
	nextButton.setSensitive(false);
	inputEntryRev.setRevealChild(false);
	nextButtonRevealer.setRevealChild(false);
}

// Staggers the input page entry and button into view
public void animateInputPage(
	Revealer inputEntryRev, Revealer nextButtonRevealer) {
	revealAfterDelay(inputEntryRev, CONTENT_REVEAL_DELAY_MS);
	revealAfterDelay(nextButtonRevealer, ACTION_REVEAL_DELAY_MS);
}
