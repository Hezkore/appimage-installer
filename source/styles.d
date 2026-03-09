// CSS helpers and shared widget factories
//
module styles;

import gdk.display : Display;
import gtk.css_provider : CssProvider;
import gtk.style_context : StyleContext;

import constants : CSS_PRIORITY_APP;

// Loads the CSS for the whole app into the default GDK display
void applyGlobalStyles() {
	auto cssProvider = new CssProvider;
	string css = `
		/* Typography */
		.title-1 { font-size: 26pt; font-weight: 800; }
		.title-2 { font-size: 20pt; font-weight: 800; }
		.title-3 { font-size: 16pt; font-weight: 700; }
		.heading  { font-size: 10pt; font-weight: 700; }
		.caption-heading { font-size: 9pt; font-weight: 700; }
		.caption  { font-size: 9pt; }
		.body     { line-height: 1.4; }

		/* Dimmed text */
		.dim-label, .dimmed { opacity: 0.55; }

		/* Semantic colours */
		.success { color: @success_color; }
		.warning { color: @warning_color; }
		.error   { color: @error_color;   }

		/* Section labels */
		.section-heading {
			font-size: smaller;
			font-weight: bold;
			opacity: 0.55;
			letter-spacing: 0.04em;
			text-transform: uppercase;
		}

		/* Pill buttons */
		button.pill {
			border-radius: 9999px;
			padding-left: 20px;
			padding-right: 20px;
		}

		/* Icon sizes */
		.icon-large  { -gtk-icon-size: 64px; }
		.icon-medium { -gtk-icon-size: 48px; }
		.icon-small  { -gtk-icon-size: 32px; }

		/* Banners */
		.info-banner {
			background-color: @theme_selected_bg_color;
			color: @theme_selected_fg_color;
			padding: 10px 16px;
		}
		.info-banner label { color: inherit; }

		.success-banner {
			background-color: @success_color;
			color: @theme_selected_fg_color;
			padding: 10px 16px;
		}
		.success-banner label { color: inherit; }

		.warning-banner {
			background-color: @warning_color;
			color: @theme_selected_fg_color;
			padding: 10px 16px;
		}
		.warning-banner label { color: inherit; }

		/* Dismiss button inside any banner */
		.banner-dismiss { color: inherit; min-height: 0; }

		/* Error labels */
		.error-label { color: @error_color; }

		/* Success banner buttons */
		button.success-banner-btn,
		button.success-banner-btn:focus {
			background-color: @success_color;
			color: @theme_selected_fg_color;
			border: 1px solid alpha(@theme_selected_fg_color, 0.3);
			box-shadow: none;
		}
		button.success-banner-btn:hover  { background-color: shade(@success_color, 1.12); }
		button.success-banner-btn:active { background-color: shade(@success_color, 0.88); }

		/* Boxed-list card styling
		   GtkListBox type-name is "list" not "listbox"
		   alpha() only takes named colours so use rgba() for black and white */
		list.boxed-list {
			background-color: @theme_base_color;
			border-radius: 12px;
			border: 1px solid alpha(@theme_fg_color, 0.12);
			box-shadow:
				0 2px 8px  rgba(0, 0, 0, 0.12),
				0 1px 2px  rgba(0, 0, 0, 0.08);
		}
		list.boxed-list > row {
			background-color: @theme_base_color;
		}
		list.boxed-list > row:first-child {
			border-radius: 11px 11px 0 0;
		}
		list.boxed-list > row:last-child {
			border-radius: 0 0 11px 11px;
		}
		list.boxed-list > row:only-child {
			border-radius: 11px;
		}
		list.boxed-list > row + row {
			border-top: 1px solid alpha(@theme_fg_color, 0.08);
		}
		list.boxed-list > row > revealer {
			background-color: transparent;
		}
		list.boxed-list > row.open-row {
			background-image: linear-gradient(
				rgba(128, 128, 128, 0.09),
				rgba(128, 128, 128, 0.09));
		}
		list.boxed-list > row:selected {
			background-color: rgba(128, 128, 128, 0.09);
		}
		list.boxed-list > row:selected label {
			color: @theme_fg_color;
		}
		list.boxed-list > row:hover {
			background-color: mix(@theme_selected_bg_color, @theme_base_color, 0.07);
		}
		list.boxed-list > row.open-row:hover {
			background-image: none;
		}

		/* Chevron */
		.row-chevron { opacity: 0.4; }
		.row-chevron.open { opacity: 0.9; }

		/* Entry placeholder text - GTK4 node path: entry > text > placeholder */
		entry > text > placeholder { opacity: 0.45; }
	`;
	cssProvider.loadFromData(css, css.length);
	StyleContext.addProviderForDisplay(Display.getDefault(), cssProvider, CSS_PRIORITY_APP);
}
