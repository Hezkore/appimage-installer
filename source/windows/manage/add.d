// Screen reached from the manage window to install a new AppImage
module windows.manage.add;

import core.atomic : atomicLoad;
import std.json : JSONValue;
import std.net.curl : CurlException, fetchUrlToFile = download;
import std.path : baseName, buildPath, stripExtension;
import std.stdio : writeln;
import std.string : endsWith, indexOf, split, startsWith, strip;

import gdk.texture : Texture;
import gdkpixbuf.pixbuf : Pixbuf;
import glib.error : ErrorWrap;
import glib.global : timeoutAdd;
import glib.types : PRIORITY_DEFAULT;
import gtk.box : Box;
import gtk.button : Button;
import gtk.entry : Entry;
import gtk.image : Image;
import gtk.label : Label;
import gtk.list_box : ListBox;
import gtk.list_box_row : ListBoxRow;
import gtk.progress_bar : ProgressBar;
import gtk.revealer : Revealer;
import gtk.scrolled_window : ScrolledWindow;
import gtk.stack : Stack;
import gtk.types : Align, Justification, Orientation, PolicyType;
import gtk.types : RevealerTransitionType, SelectionMode, StackTransitionType;
import pango.types : EllipsizeMode;

import apputils : isAppImageAssociated, associateAppImages;
import constants : TAG_LATEST, TAG_LATEST_PRE, TAG_LATEST_ALL;
import lang : L;
import update.common : downloadFile;
import update.githubcommon : fetchGitHubRelease;
import update.pling : resolvePlingAppImageUrl;
import windows.base : makeBackButton, makeSlideDownRevealer, REVEAL_MS;
import windows.manage : ManageWindow;

private enum int SLIDE_MS = 300;
private enum int CARD_PADDING = 14;
private enum int CARD_ICON_SIZE = 32;
private enum int CARD_ICON_MARGIN = 14;
private enum int CARD_TEXT_SPACING = 3;
private enum int HERO_ICON_SIZE = 64;
private enum int HERO_MARGIN = 24;
private enum int PAGE_MARGIN = 16;
private enum int URL_ROW_SPACING = 4;
private enum int INSTALL_BTN_HEIGHT = 48;
private enum int INSTALL_BTN_TOP = 8;
private enum int POLL_MS = 100;
private enum int PROGRESS_BAR_MIN_WIDTH = 280;
private enum int PAGE_STACK_SPACING = 12;
private enum int DOWNLOAD_NAME_MAX_CHARS = 32;
private enum int DOWNLOAD_SOURCE_MAX_CHARS = 40;

// What kind of URL the user typed in the entry
private enum UrlKind {
	unknown,
	github,
	pling,
	direct,
}

// GitHub release asset with name and download URL
private struct GitHubAsset {
	string name;
	string url;
}

// Holds download result state shared between the worker thread and GTK thread
private class DownloadState {
	string tempPath;
	string updateInfo;
	string error;
	// Written by background worker, polled by main thread for progress display
	double downloadProgress;
	GitHubAsset[] resolvedGitHubAssets;
	string resolvedDownloadUrl;
	string resolvedAppName;
	string resolvedSource;
	string resolvedIconPath;
}

// Returns "owner/repo" from a GitHub project URL, or "" if not a GitHub URL
private string extractGitHubRepository(string url) {
	foreach (prefix; [
			"https://github.com/", "http://github.com/",
			"github.com/"
		]) {
		if (!url.startsWith(prefix))
			continue;
		string rest = url[prefix.length .. $];
		if (rest.endsWith("/"))
			rest = rest[0 .. $ - 1];
		auto parts = rest.split("/");
		if (parts.length >= 2
			&& parts[0].length > 0 && parts[1].length > 0)
			return parts[0] ~ "/" ~ parts[1];
	}
	return "";
}

// Returns the numeric product ID from a Pling or KDE Store URL, or ""
private string extractPlingProductId(string url) {
	foreach (host; [
			"pling.com/p/", "www.pling.com/p/",
			"store.kde.org/p/", "www.store.kde.org/p/"
		]) {
		auto hostStart = url.indexOf(host);
		if (hostStart < 0)
			continue;
		string after = url[hostStart + host.length .. $];
		if (after.endsWith("/"))
			after = after[0 .. $ - 1];
		auto slashIndex = after.indexOf("/");
		if (slashIndex > 0)
			after = after[0 .. slashIndex];
		if (after.length > 0)
			return after;
	}
	return "";
}

// Returns the kind of URL and populates gitHubRepository or plingProductId for that kind
private UrlKind detectUrl(
	string url,
	out string gitHubRepository,
	out string plingProductId) {
	url = url.strip();
	gitHubRepository = "";
	plingProductId = "";
	if (url.length == 0)
		return UrlKind.unknown;
	gitHubRepository = extractGitHubRepository(url);
	if (gitHubRepository.length > 0)
		return UrlKind.github;
	plingProductId = extractPlingProductId(url);
	if (plingProductId.length > 0)
		return UrlKind.pling;
	if ((url.startsWith("http://") || url.startsWith("https://"))
		&& (url.endsWith(".AppImage") || url.endsWith(".appimage")))
		return UrlKind.direct;
	return UrlKind.unknown;
}

// Non-interactive row describing one way to install an AppImage
private ListBoxRow makeInfoCard(
	string iconName, string title, string subtitle) {
	auto row = new ListBoxRow;
	row.setActivatable(false);
	row.setSelectable(false);
	auto inner = new Box(Orientation.Horizontal, 0);
	inner.setMarginTop(CARD_PADDING);
	inner.setMarginBottom(CARD_PADDING);
	inner.setMarginStart(CARD_PADDING);
	inner.setMarginEnd(CARD_PADDING);
	auto icon = Image.newFromIconName(iconName);
	icon.setPixelSize(CARD_ICON_SIZE);
	icon.setHalign(Align.Center);
	icon.setValign(Align.Center);
	icon.setMarginEnd(CARD_ICON_MARGIN);
	inner.append(icon);
	auto textColumn = new Box(Orientation.Vertical, CARD_TEXT_SPACING);
	textColumn.setValign(Align.Center);
	textColumn.setHexpand(true);
	auto titleLabel = new Label(title);
	titleLabel.setHalign(Align.Start);
	textColumn.append(titleLabel);
	auto subtitleLabel = new Label(subtitle);
	subtitleLabel.setHalign(Align.Start);
	subtitleLabel.setWrap(true);
	subtitleLabel.addCssClass("dim-label");
	textColumn.append(subtitleLabel);
	inner.append(textColumn);
	row.setChild(inner);
	return row;
}

// Builds info cards plus URL entry with live URL detection and download button
private Box buildInfoContent(
	ManageWindow win, Stack pageStack,
	Label errorLabel, DownloadState state,
	ProgressBar downloadProgressBar,
	Image downloadIconImage,
	Label downloadNameLabel,
	Label downloadSourceLabel,
	void delegate() onDisableBack,
	void delegate() onEnableBack) {
	auto list = new ListBox;
	list.setSelectionMode(SelectionMode.None);
	list.addCssClass("boxed-list");

	bool associated = isAppImageAssociated();

	auto openCard = makeInfoCard(
		"folder-open-symbolic",
		L("add.method.open.title"), L("add.method.open.sub"));
	if (!associated)
		openCard.hide();

	// Warn when AppImages are not set to open with this installer
	if (!associated) {
		auto assocRow = new ListBoxRow;
		assocRow.setActivatable(false);
		assocRow.setSelectable(false);
		auto assocInner = new Box(Orientation.Horizontal, CARD_PADDING);
		assocInner.setMarginTop(CARD_PADDING);
		assocInner.setMarginBottom(CARD_PADDING);
		assocInner.setMarginStart(CARD_PADDING);
		assocInner.setMarginEnd(CARD_PADDING);
		auto assocIcon = Image.newFromIconName("dialog-warning-symbolic");
		assocIcon.setPixelSize(CARD_ICON_SIZE);
		assocIcon.setHalign(Align.Center);
		assocIcon.setValign(Align.Center);
		assocIcon.setMarginEnd(CARD_ICON_MARGIN);
		auto assocLabel = new Label(L("add.association.warning"));
		assocLabel.setHalign(Align.Start);
		assocLabel.setHexpand(true);
		assocLabel.setWrap(true);
		auto assocButton = Button.newWithLabel(L("add.association.fix"));
		assocButton.setValign(Align.Center);
		assocButton.connectClicked(() {
			string assocError;
			if (associateAppImages(assocError)) {
				assocRow.hide();
				openCard.show();
			} else {
				assocIcon.setFromIconName("dialog-error-symbolic");
				assocLabel.setText(assocError);
				assocButton.hide();
			}
		});
		assocInner.append(assocIcon);
		assocInner.append(assocLabel);
		assocInner.append(assocButton);
		assocRow.setChild(assocInner);
		list.append(assocRow);
	}

	list.append(openCard);
	list.append(makeInfoCard(
			"emblem-downloads-symbolic",
			L("add.method.drag.title"), L("add.method.drag.sub")));
	list.append(makeInfoCard(
			"network-transmit-symbolic",
			L("add.method.url.title"), L("add.method.url.sub")));

	auto urlRow = new ListBoxRow;
	urlRow.setActivatable(false);
	urlRow.setSelectable(false);
	auto urlBox = new Box(Orientation.Vertical, 0);
	urlBox.setMarginTop(CARD_PADDING);
	urlBox.setMarginBottom(CARD_PADDING);
	urlBox.setMarginStart(CARD_PADDING);
	urlBox.setMarginEnd(CARD_PADDING);
	auto urlEntry = new Entry;
	urlEntry.setPlaceholderText(L("add.url.placeholder"));
	urlEntry.setHexpand(true);
	urlBox.append(urlEntry);
	auto statusLabel = new Label("");
	statusLabel.setHalign(Align.Start);
	statusLabel.addCssClass("dim-label");
	statusLabel.setMarginTop(URL_ROW_SPACING);
	statusLabel.setVisible(false);
	urlBox.append(statusLabel);
	auto installButton = new Button;
	installButton.setLabel(L("add.url.button"));
	installButton.addCssClass("suggested-action");
	installButton.setHexpand(true);
	installButton.setMarginTop(INSTALL_BTN_TOP);
	installButton.setSizeRequest(-1, INSTALL_BTN_HEIGHT);
	installButton.setSensitive(false);
	auto installRevealer = makeSlideDownRevealer(REVEAL_MS);
	installRevealer.setChild(installButton);
	urlBox.append(installRevealer);
	urlRow.setChild(urlBox);
	list.append(urlRow);

	UrlKind currentKind = UrlKind.unknown;
	string capturedGitHubRepository;
	string capturedPlingProductId;

	urlEntry.connectChanged(() {
		string text = urlEntry.getText().strip();
		string gitHubRepository;
		string plingProductId;
		currentKind = detectUrl(
			text,
			gitHubRepository,
			plingProductId);
		capturedGitHubRepository = gitHubRepository;
		capturedPlingProductId = plingProductId;
		final switch (currentKind) {
		case UrlKind.github:
			statusLabel.setText(
				L("add.url.detected.github", gitHubRepository));
			statusLabel.setVisible(true);
			installButton.setSensitive(true);
			installRevealer.setRevealChild(true);
			break;
		case UrlKind.pling:
			statusLabel.setText(
				L("add.url.detected.pling", plingProductId));
			statusLabel.setVisible(true);
			installButton.setSensitive(true);
			installRevealer.setRevealChild(true);
			break;
		case UrlKind.direct:
			statusLabel.setText(L("add.url.detected.direct"));
			statusLabel.setVisible(true);
			installButton.setSensitive(true);
			installRevealer.setRevealChild(true);
			break;
		case UrlKind.unknown:
			statusLabel.setVisible(text.length > 0);
			if (text.length > 0)
				statusLabel.setText(L("add.url.unknown"));
			installButton.setSensitive(false);
			installRevealer.setRevealChild(false);
			break;
		}
	});

	installButton.connectClicked(() {
		string urlText = urlEntry.getText().strip();
		UrlKind kind = currentKind;
		string gitHubRepository = capturedGitHubRepository;
		string plingProductId = capturedPlingProductId;
		state.error = "";
		state.tempPath = "";
		state.updateInfo = "";
		state.resolvedGitHubAssets = [];
		state.resolvedDownloadUrl = "";
		state.resolvedAppName = "";
		state.resolvedSource = "";
		state.resolvedIconPath = "";
		state.downloadProgress = 0.0;
		downloadProgressBar.setFraction(0.0);
		downloadProgressBar.setText(L("add.downloading.resolving"));
		downloadIconImage.setFromIconName("package-x-generic-symbolic");

		void delegate(string) resolveAndDownload;
		resolveAndDownload = (string gitHubTag) {
			if (kind == UrlKind.github) {
				auto repositoryParts = gitHubRepository.split("/");
				downloadNameLabel.setText(
					repositoryParts.length >= 2
					? repositoryParts[1] : gitHubRepository);
				downloadSourceLabel.setText(
					L("add.source.github", gitHubRepository));
				downloadSourceLabel.setVisible(true);
			} else if (kind == UrlKind.pling) {
				downloadNameLabel.setText(L("add.downloading.title"));
				downloadSourceLabel.setText(
					L("add.source.pling", plingProductId));
				downloadSourceLabel.setVisible(true);
			} else {
				downloadNameLabel.setText(baseName(urlText).stripExtension);
				downloadSourceLabel.setText(urlText);
				downloadSourceLabel.setVisible(true);
			}
			onDisableBack();
			pageStack.setTransitionType(StackTransitionType.SlideLeft);
			pageStack.setVisibleChildName("downloading");

			void delegate(string) startDownload;
			startDownload = (string downloadUrl) {
				import std.file : tempDir;
				import std.format : format;
				import std.random : uniform;

				state.downloadProgress = 0.0;
				downloadProgressBar.setFraction(0.0);
				downloadProgressBar.setText(L("add.downloading.resolving"));
				downloadSourceLabel.setText(baseName(downloadUrl));
				downloadSourceLabel.setVisible(true);
				pageStack.setTransitionType(StackTransitionType.SlideLeft);
				pageStack.setVisibleChildName("downloading");
				bool[] dlDone = [false];
				timeoutAdd(PRIORITY_DEFAULT, POLL_MS, () {
					if (!dlDone[0]) {
						downloadProgressBar.setFraction(
						state.downloadProgress);
						downloadProgressBar.setText(
						L("add.downloading.progress",
						cast(int)(state.downloadProgress * 100)));
					}
					return !dlDone[0];
				});
				win.doThreadedWork(
					() {
					string stem = stripExtension(baseName(downloadUrl));
					state.tempPath = buildPath(tempDir(),
					format("%s_%08x.AppImage", stem, uniform!uint()));
					string downloadError;
					if (!downloadFile(downloadUrl, state.tempPath,
						state.downloadProgress, 0.0, 1.0, downloadError,
						() => cast(bool) atomicLoad(win.workCancelled)))
						state.error = downloadError;
					else
						writeln("add: downloaded to ", state.tempPath);
				},
					() {
					dlDone[0] = true;
					if (state.error.length > 0) {
						onEnableBack();
						errorLabel.setText(state.error);
						pageStack.setTransitionType(
						StackTransitionType.SlideLeft);
						pageStack.setVisibleChildName("error");
					} else {
						win.openFileForInstall(
						state.tempPath, state.updateInfo);
					}
				});
			};

			bool[] resolveDone = [false];
			timeoutAdd(PRIORITY_DEFAULT, POLL_MS, () {
				if (!resolveDone[0])
					downloadProgressBar.pulse();
				return !resolveDone[0];
			});
			win.doThreadedWork(
				() {
				if (kind == UrlKind.github) {
					import std.file : tempDir;

					auto repositoryParts = gitHubRepository.split("/");
					string ownerName = repositoryParts[0];
					string repositoryName = repositoryParts[1];
					state.resolvedAppName = repositoryName;
					state.resolvedSource = L(
					"add.source.github",
					gitHubRepository);
					string gitHubIconPath = buildPath(
					tempDir(), ownerName ~ ".gh.png");
					try {
						fetchUrlToFile(
						"https://github.com/" ~ ownerName ~ ".png?size=64",
						gitHubIconPath);
						state.resolvedIconPath = gitHubIconPath;
					} catch (CurlException) {
					}
					JSONValue releaseJson;
					string fetchError;
					if (!fetchGitHubRelease(ownerName, repositoryName, gitHubTag,
						releaseJson, fetchError)) {
						state.error = fetchError;
						return;
					}
					auto assetsPtr = "assets" in releaseJson;
					if (assetsPtr is null) {
						state.error = L("add.error.no_assets");
						return;
					}
					foreach (asset; assetsPtr.array) {
						string name = asset["name"].str;
						if (!name.endsWith(".AppImage")
						&& !name.endsWith(".appimage"))
							continue;
						state.resolvedGitHubAssets ~= GitHubAsset(name,
						asset["browser_download_url"].str);
						writeln("add: GitHub asset found: ", name);
					}
					if (state.resolvedGitHubAssets.length == 0) {
						state.error = L("add.error.no_appimage");
						return;
					}
					if (state.resolvedGitHubAssets.length == 1) {
						string name = state.resolvedGitHubAssets[0].name;
						state.resolvedDownloadUrl =
						state.resolvedGitHubAssets[0].url;
						state.updateInfo = "gh-releases|" ~ ownerName
						~ "|" ~ repositoryName
						~ "|" ~ gitHubTag
						~ "|" ~ name;
					}
				} else if (kind == UrlKind.pling) {
					import std.file : tempDir;

					string downloadUrl;
					string plingPattern;
					string plingAppName;
					string plingIconUrl;
					string plingError;
					if (!resolvePlingAppImageUrl(plingProductId, downloadUrl,
						plingPattern, plingAppName, plingIconUrl,
						plingError)) {
						state.error = plingError;
						return;
					}
					state.resolvedAppName = plingAppName;
					state.resolvedSource = L(
					"add.source.pling",
					plingProductId);
					if (plingIconUrl.length) {
						string plingIconPath = buildPath(
						tempDir(), plingProductId ~ ".pling.jpg");
						try {
							fetchUrlToFile(plingIconUrl, plingIconPath);
							state.resolvedIconPath = plingIconPath;
						} catch (CurlException) {
						}
					}
					state.updateInfo = "pling-v1-zsync|"
					~ plingProductId ~ "|" ~ plingPattern;
					state.resolvedDownloadUrl = downloadUrl;
					writeln("add: Pling resolved to ", downloadUrl);
				} else {
					state.resolvedDownloadUrl = urlText;
					state.updateInfo = "direct-link|" ~ urlText;
					state.resolvedAppName =
					baseName(urlText).stripExtension;
				}
			},
				() {
				resolveDone[0] = true;
				if (state.resolvedAppName.length)
					downloadNameLabel.setText(state.resolvedAppName);
				if (state.resolvedSource.length)
					downloadSourceLabel.setText(state.resolvedSource);
				if (state.resolvedIconPath.length) {
					try {
						import std.file : exists;

						if (exists(state.resolvedIconPath)) {
							auto pix = Pixbuf.newFromFileAtScale(
							state.resolvedIconPath,
							HERO_ICON_SIZE, HERO_ICON_SIZE, true);
							if (pix !is null)
								downloadIconImage.setFromPaintable(
								Texture.newForPixbuf(pix));
						}
					} catch (ErrorWrap error) {
						writeln("add: icon load failed: ", error.msg);
					}
				}
				if (state.error.length > 0) {
					errorLabel.setText(state.error);
					pageStack.setTransitionType(
					StackTransitionType.SlideLeft);
					pageStack.setVisibleChildName("error");
					return;
				}
				if (state.resolvedGitHubAssets.length > 1) {
					GitHubAsset[] assets = state.resolvedGitHubAssets;
					auto repositoryParts = gitHubRepository.split("/");
					string ownerName = repositoryParts[0];
					string repositoryName = repositoryParts[1];
					auto assetList = new ListBox;
					assetList.setHexpand(true);
					assetList.addCssClass("boxed-list");
					assetList.setSelectionMode(SelectionMode.None);
					foreach (ga; assets) {
						auto pickRow = new ListBoxRow;
						auto pickInner = new Box(
						Orientation.Horizontal, 0);
						pickInner.setMarginTop(CARD_PADDING);
						pickInner.setMarginBottom(CARD_PADDING);
						pickInner.setMarginStart(CARD_PADDING);
						pickInner.setMarginEnd(CARD_PADDING);
						auto pickIcon = Image.newFromIconName(
						"package-x-generic-symbolic");
						pickIcon.setPixelSize(CARD_ICON_SIZE);
						pickIcon.setMarginEnd(CARD_ICON_MARGIN);
						auto pickLabel = new Label(ga.name);
						pickLabel.setHalign(Align.Start);
						pickLabel.setHexpand(true);
						pickInner.append(pickIcon);
						pickInner.append(pickLabel);
						pickRow.setChild(pickInner);
						assetList.append(pickRow);
					}
					assetList.connectRowActivated(
					(ListBoxRow row, ListBox listBox) {
						int rowIndex = row.getIndex();
						if (rowIndex < 0
						|| rowIndex >= cast(int) assets.length)
							return;
						GitHubAsset chosen = assets[rowIndex];
						state.updateInfo = "gh-releases|"
						~ ownerName ~ "|" ~ repositoryName
						~ "|" ~ gitHubTag
						~ "|" ~ chosen.name;
						onDisableBack();
						startDownload(chosen.url);
					});
					auto pickTitle = new Label(L("add.pick.title"));
					pickTitle.addCssClass("title-3");
					pickTitle.setHalign(Align.Center);
					pickTitle.setMarginBottom(PAGE_MARGIN);
					auto pickContent = new Box(Orientation.Vertical, 0);
					pickContent.setHexpand(true);
					pickContent.setMarginStart(PAGE_MARGIN);
					pickContent.setMarginEnd(PAGE_MARGIN);
					pickContent.append(pickTitle);
					pickContent.append(assetList);
					auto pickScroll = new ScrolledWindow;
					pickScroll.setHexpand(true);
					pickScroll.setVexpand(true);
					pickScroll.setPolicy(
					PolicyType.Never, PolicyType.Automatic);
					pickScroll.setChild(pickContent);
					pageStack.addNamed(pickScroll, "pick");
					onEnableBack();
					pageStack.setTransitionType(
					StackTransitionType.SlideLeft);
					pageStack.setVisibleChildName("pick");
				} else {
					startDownload(state.resolvedDownloadUrl);
				}
			});
		};

		if (kind != UrlKind.github) {
			resolveAndDownload("");
			return;
		}

		// GitHub URL so let the user choose a release type before fetching
		auto makeReleaseCard = (string iconName, string title,
			string subtitle) {
			auto cardIcon = Image.newFromIconName(iconName);
			cardIcon.setPixelSize(CARD_ICON_SIZE);
			cardIcon.setValign(Align.Center);
			cardIcon.setMarginEnd(CARD_ICON_MARGIN);
			auto titleLbl = new Label(title);
			titleLbl.addCssClass("heading");
			titleLbl.setHalign(Align.Start);
			auto subtitleLbl = new Label(subtitle);
			subtitleLbl.addCssClass("caption");
			subtitleLbl.addCssClass("dim-label");
			subtitleLbl.setHalign(Align.Start);
			auto textCol = new Box(Orientation.Vertical, CARD_TEXT_SPACING);
			textCol.setValign(Align.Center);
			textCol.setHexpand(true);
			textCol.append(titleLbl);
			textCol.append(subtitleLbl);
			auto rowBox = new Box(Orientation.Horizontal, 0);
			rowBox.setMarginTop(CARD_PADDING);
			rowBox.setMarginBottom(CARD_PADDING);
			rowBox.setMarginStart(CARD_PADDING);
			rowBox.setMarginEnd(CARD_PADDING);
			rowBox.append(cardIcon);
			rowBox.append(textCol);
			auto row = new ListBoxRow;
			row.setChild(rowBox);
			return row;
		};

		auto releaseList = new ListBox;
		releaseList.addCssClass("boxed-list");
		releaseList.setSelectionMode(SelectionMode.None);
		releaseList.append(makeReleaseCard(
			"emblem-ok-symbolic",
			L("options.update.release.latest"),
			L("options.update.release.latest.sub")));
		releaseList.append(makeReleaseCard(
			"emblem-important-symbolic",
			L("options.update.release.pre"),
			L("options.update.release.pre.sub")));
		releaseList.append(makeReleaseCard(
			"view-more-symbolic",
			L("options.update.release.all"),
			L("options.update.release.all.sub")));
		releaseList.append(makeReleaseCard(
			"bookmark-new-symbolic",
			L("options.update.release.specific"),
			L("options.update.release.specific.sub")));

		auto customTagBox = new ListBox;
		customTagBox.addCssClass("boxed-list");
		customTagBox.setSelectionMode(SelectionMode.None);
		customTagBox.setMarginTop(URL_ROW_SPACING);
		customTagBox.setVisible(false);
		auto customTagEntry = new Entry;
		customTagEntry.setPlaceholderText(L("add.release.tag.placeholder"));
		customTagEntry.setHexpand(true);
		auto customTagInner = new Box(Orientation.Horizontal, 0);
		customTagInner.setMarginTop(CARD_PADDING);
		customTagInner.setMarginBottom(CARD_PADDING);
		customTagInner.setMarginStart(CARD_PADDING);
		customTagInner.setMarginEnd(CARD_PADDING);
		customTagInner.append(customTagEntry);
		auto customTagRow = new ListBoxRow;
		customTagRow.setActivatable(false);
		customTagRow.setChild(customTagInner);
		customTagBox.append(customTagRow);

		auto continueButton = new Button;
		continueButton.setLabel(L("add.release.continue"));
		continueButton.setHexpand(true);
		continueButton.setMarginTop(INSTALL_BTN_TOP);
		continueButton.setSizeRequest(-1, INSTALL_BTN_HEIGHT);
		auto continueRevealer = makeSlideDownRevealer(REVEAL_MS);
		continueRevealer.setChild(continueButton);

		releaseList.connectRowActivated((ListBoxRow row, ListBox listBox) {
			int rowIndex = row.getIndex();
			string[] tags = [TAG_LATEST, TAG_LATEST_PRE, TAG_LATEST_ALL];
			if (rowIndex < 3) {
				resolveAndDownload(tags[rowIndex]);
			} else {
				customTagBox.setVisible(true);
				continueRevealer.setRevealChild(true);
				customTagEntry.grabFocus();
			}
		});

		continueButton.connectClicked(() {
			string tag = customTagEntry.getText().strip();
			if (!tag.length)
				return;
			resolveAndDownload(tag);
		});

		auto releaseTitle = new Label(L("add.release.title"));
		releaseTitle.addCssClass("title-3");
		releaseTitle.setHalign(Align.Center);
		releaseTitle.setMarginBottom(PAGE_MARGIN);
		auto releaseContent = new Box(Orientation.Vertical, 0);
		releaseContent.setHexpand(true);
		releaseContent.setMarginStart(PAGE_MARGIN);
		releaseContent.setMarginEnd(PAGE_MARGIN);
		releaseContent.append(releaseTitle);
		releaseContent.append(releaseList);
		releaseContent.append(customTagBox);
		releaseContent.append(continueRevealer);
		auto releaseScroll = new ScrolledWindow;
		releaseScroll.setHexpand(true);
		releaseScroll.setVexpand(true);
		releaseScroll.setPolicy(PolicyType.Never, PolicyType.Automatic);
		releaseScroll.setChild(releaseContent);
		pageStack.addNamed(releaseScroll, "release-type");
		onEnableBack();
		pageStack.setTransitionType(StackTransitionType.SlideLeft);
		pageStack.setVisibleChildName("release-type");
	});

	auto heroIcon = Image.newFromIconName(
		"package-x-generic-symbolic");
	heroIcon.setPixelSize(HERO_ICON_SIZE);
	heroIcon.setHalign(Align.Center);
	heroIcon.setMarginTop(HERO_MARGIN);
	heroIcon.setMarginBottom(HERO_MARGIN);
	auto titleLabel = new Label(L("add.title"));
	titleLabel.setHalign(Align.Center);
	titleLabel.addCssClass("title-3");
	titleLabel.setMarginBottom(PAGE_MARGIN);
	auto content = new Box(Orientation.Vertical, 0);
	content.setHexpand(true);
	content.setMarginStart(PAGE_MARGIN);
	content.setMarginEnd(PAGE_MARGIN);
	content.setMarginBottom(PAGE_MARGIN);
	content.append(heroIcon);
	content.append(titleLabel);
	content.append(list);
	return content;
}

// Builds the "install a new AppImage" sub-page and installs a back button
// Calls onDone and removes the back button when the user navigates back
public Box buildAddAppBox(ManageWindow win, void delegate() onDone) {
	auto state = new DownloadState;
	auto errorLabel = new Label("");
	errorLabel.addCssClass("dim-label");
	errorLabel.setWrap(true);
	errorLabel.setJustify(Justification.Center);

	auto pageStack = new Stack;
	pageStack.setHexpand(true);
	pageStack.setVexpand(true);
	pageStack.setTransitionDuration(SLIDE_MS);

	auto scroll = new ScrolledWindow;
	scroll.setHexpand(true);
	scroll.setVexpand(true);
	scroll.setPolicy(PolicyType.Never, PolicyType.Automatic);

	auto downloadProgressBar = new ProgressBar;
	downloadProgressBar.setHexpand(true);
	downloadProgressBar.setSizeRequest(PROGRESS_BAR_MIN_WIDTH, -1);
	downloadProgressBar.setShowText(true);
	downloadProgressBar.setText(L("add.downloading.resolving"));

	auto downloadIconImage = Image.newFromIconName(
		"package-x-generic-symbolic");
	downloadIconImage.setPixelSize(HERO_ICON_SIZE);
	downloadIconImage.setHalign(Align.Center);

	auto downloadNameLabel = new Label(L("add.downloading.title"));
	downloadNameLabel.addCssClass("title-3");
	downloadNameLabel.setHalign(Align.Center);
	downloadNameLabel.setEllipsize(EllipsizeMode.End);
	downloadNameLabel.setMaxWidthChars(DOWNLOAD_NAME_MAX_CHARS);

	auto downloadSourceLabel = new Label("");
	downloadSourceLabel.addCssClass("dim-label");
	downloadSourceLabel.setHalign(Align.Center);
	downloadSourceLabel.setEllipsize(EllipsizeMode.Middle);
	downloadSourceLabel.setMaxWidthChars(DOWNLOAD_SOURCE_MAX_CHARS);
	downloadSourceLabel.setVisible(false);

	Button backButton;

	scroll.setChild(
		buildInfoContent(win, pageStack, errorLabel, state,
			downloadProgressBar, downloadIconImage,
			downloadNameLabel, downloadSourceLabel,
			() { backButton.setSensitive(false); },
			() { backButton.setSensitive(true); }));
	pageStack.addNamed(scroll, "info");

	auto downloadBox = new Box(Orientation.Vertical, PAGE_STACK_SPACING);
	downloadBox.setHexpand(true);
	downloadBox.setVexpand(true);
	downloadBox.setHalign(Align.Center);
	downloadBox.setValign(Align.Center);
	downloadBox.setMarginStart(PAGE_MARGIN);
	downloadBox.setMarginEnd(PAGE_MARGIN);
	downloadBox.append(downloadIconImage);
	downloadBox.append(downloadNameLabel);
	downloadBox.append(downloadSourceLabel);
	downloadBox.append(downloadProgressBar);
	pageStack.addNamed(downloadBox, "downloading");

	auto errorBox = new Box(Orientation.Vertical, PAGE_STACK_SPACING);
	errorBox.setHexpand(true);
	errorBox.setVexpand(true);
	errorBox.setHalign(Align.Center);
	errorBox.setValign(Align.Center);
	auto errorIcon =
		Image.newFromIconName("dialog-warning-symbolic");
	errorIcon.setPixelSize(HERO_ICON_SIZE);
	errorBox.append(errorIcon);
	auto errorTitle = new Label(L("add.error.title"));
	errorTitle.addCssClass("title-3");
	errorBox.append(errorTitle);
	errorBox.append(errorLabel);
	auto retryButton = new Button;
	retryButton.setLabel(L("add.error.retry"));
	retryButton.setHalign(Align.Center);
	retryButton.setMarginTop(INSTALL_BTN_TOP);
	retryButton.connectClicked(() {
		backButton.setSensitive(true);
		pageStack.setTransitionType(StackTransitionType.SlideRight);
		pageStack.setVisibleChildName("info");
	});
	errorBox.append(retryButton);
	pageStack.addNamed(errorBox, "error");
	pageStack.setVisibleChildName("info");

	backButton = makeBackButton(() { win.headerBar.remove(backButton); onDone(); });
	win.headerBar.packStart(backButton);

	auto outerBox = new Box(Orientation.Vertical, 0);
	outerBox.setHexpand(true);
	outerBox.setVexpand(true);
	outerBox.append(pageStack);
	return outerBox;
}
