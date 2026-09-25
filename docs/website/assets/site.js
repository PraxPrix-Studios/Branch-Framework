// Branch docs: shared chrome for every page (top bar, sidebar, pager,
// search, "on this page" list, heading links), Luau highlighting and copy
// buttons. Pages set data-root (path to the site root) and data-page (their
// key in NAV) on <body>; data-no-toc turns the "on this page" list off.
(function () {
	var NAV = [
		{ group: "start", title: "Start", pages: [
			["index", "Home"],
			["getting-started", "Getting started"],
			["tutorial", "Tutorial: a coin game"],
			["features", "Unique features"],
		] },
		{ group: "guide", title: "Guides", pages: [
			["guide/segments", "Segments"],
			["guide/data", "Player data"],
			["guide/network", "Networking"],
			["guide/features", "Using the features"],
			["guide/studio", "Branch Studio"],
			["guide/troubleshooting", "Common errors"],
		] },
		{ group: "api", title: "API reference", pages: [
			["api/branch", "Branch"],
			["api/data-server", "Branch.Data.Server"],
			["api/data-client", "Branch.Data.Client"],
			["api/network", "Branch.Network"],
			["api/types", "Network types"],
			["api/util", "Utilities"],
		] },
		{ group: "perf", title: "Performance", pages: [
			["benchmarks", "Benchmarks"],
		] },
	];
	var REPO = "https://github.com/PraxPrix-Studios/Branch-Framework";

	var body = document.body;
	var root = body.getAttribute("data-root") || "";
	var here = body.getAttribute("data-page") || "index";
	var href = function (key) { return root + key + ".html"; };
	var escape = function (text) { return text.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;"); };
	var isMac = /Mac|iPhone|iPad/.test(navigator.platform || "");

	// top bar
	var top = document.createElement("header");
	top.className = "top";
	top.innerHTML =
		'<a class="brand" href="' + href("index") + '"><img src="' + root + 'assets/mark.png" alt="">Branch</a>' +
		'<span class="ver">v2.0.0</span>' +
		'<button class="search-open" type="button" aria-label="Search the docs"><svg viewBox="0 0 24 24" aria-hidden="true"><circle cx="10.5" cy="10.5" r="6.5"/><path d="M15.5 15.5 20 20"/></svg><span>Search</span><kbd>' + (isMac ? "⌘" : "Ctrl") + " K</kbd></button>" +
		'<nav class="links" aria-label="Main">' +
		'<a href="' + href("features") + '">Features</a>' +
		'<a href="' + href("getting-started") + '">Docs</a>' +
		'<a href="' + href("api/branch") + '">API</a>' +
		'<a href="' + href("benchmarks") + '">Benchmarks</a>' +
		'<a href="' + REPO + '">GitHub</a></nav>' +
		'<button class="menu" type="button" aria-expanded="false" aria-controls="sidebar">Menu</button>';
	body.insertBefore(top, body.firstChild);

	// sidebar
	var side = document.getElementById("sidebar");
	var flat = [];
	NAV.forEach(function (group) { group.pages.forEach(function (page) { flat.push(page); }); });
	if (side) {
		var html = "";
		NAV.forEach(function (group) {
			html += '<div class="navgroup"><h4><b>' + group.group + "</b>/ " + group.title + "</h4><ol>";
			group.pages.forEach(function (page) {
				html += '<li class="' + (page[0] === here ? "here" : "") + '"><a href="' + href(page[0]) + '"' +
					(page[0] === here ? ' aria-current="page"' : "") + ">" + page[1] + "</a></li>";
			});
			html += "</ol></div>";
		});
		side.innerHTML = html;
		var button = top.querySelector(".menu");
		button.addEventListener("click", function () {
			var open = side.classList.toggle("open");
			button.setAttribute("aria-expanded", open ? "true" : "false");
		});
	}

	// heading ids: pages and the search index give every h2 / h3 the same one
	function slug(text) {
		return text.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "") || "section";
	}
	function nameHeadings(doc) {
		var used = {};
		doc.querySelectorAll("[id]").forEach(function (node) { used[node.id] = true; });
		var list = [];
		doc.querySelectorAll(".doc h2, .doc h3").forEach(function (heading) {
			if (heading.closest(".bench")) { return; }
			var id = heading.id;
			if (!id) {
				var api = heading.parentElement && heading.parentElement.classList.contains("api") ? heading.parentElement.id : "";
				if (api) {
					id = api;
				} else {
					var base = slug(heading.textContent), candidate = base, n = 2;
					while (used[candidate]) { candidate = base + "-" + n++; }
					heading.id = candidate;
					used[candidate] = true;
					id = candidate;
				}
			}
			list.push({ node: heading, id: id, level: heading.tagName === "H2" ? 2 : 3 });
		});
		return list;
	}
	var headings = nameHeadings(document);

	// a link on every heading, to share that section
	headings.forEach(function (item) {
		var link = document.createElement("a");
		link.className = "anchor";
		link.href = "#" + item.id;
		link.setAttribute("aria-label", "Link to this section");
		link.textContent = "#";
		item.node.appendChild(link);
	});

	// "on this page"
	var doc = document.querySelector(".doc");
	var layout = document.querySelector(".layout");
	// long pages (many cards or API entries) list their sections only
	var tocItems = headings.length > 24 ? headings.filter(function (item) { return item.level === 2; }) : headings;
	if (doc && layout && !body.hasAttribute("data-no-toc") && tocItems.length >= 3) {
		var toc = document.createElement("aside");
		toc.className = "toc";
		toc.setAttribute("aria-label", "On this page");
		var items = '<h4>On this page</h4><ol>';
		tocItems.forEach(function (item) {
			var text = item.node.cloneNode(true);
			text.querySelectorAll(".anchor, .tag, .new, .auto, .studio").forEach(function (n) { n.remove(); });
			items += '<li class="l' + item.level + '"><a href="#' + item.id + '">' + escape(text.textContent.trim()) + "</a></li>";
		});
		toc.innerHTML = items + "</ol>";
		layout.appendChild(toc);
		layout.classList.add("has-toc");
		var links = {};
		toc.querySelectorAll("a").forEach(function (a) { links[a.getAttribute("href").slice(1)] = a; });
		var current = null;
		var mark = function () {
			var active = null;
			for (var i = 0; i < tocItems.length; i++) {
				if (tocItems[i].node.getBoundingClientRect().top < 120) { active = tocItems[i].id; } else { break; }
			}
			active = active || tocItems[0].id;
			if (active !== current) {
				if (current && links[current]) { links[current].classList.remove("on"); }
				if (links[active]) {
					links[active].classList.add("on");
					var box = toc.getBoundingClientRect(), at = links[active].getBoundingClientRect();
					if (at.top < box.top || at.bottom > box.bottom) { links[active].scrollIntoView({ block: "nearest" }); }
				}
				current = active;
			}
		};
		var queued = false;
		window.addEventListener("scroll", function () {
			if (!queued) { queued = true; requestAnimationFrame(function () { queued = false; mark(); }); }
		}, { passive: true });
		mark();
	}

	// previous / next
	var at = -1;
	flat.forEach(function (page, index) { if (page[0] === here) { at = index; } });
	if (doc && at >= 0 && !doc.hasAttribute("data-no-pager")) {
		var pager = document.createElement("nav");
		pager.className = "pager";
		pager.setAttribute("aria-label", "Pages");
		var prev = flat[at - 1], next = flat[at + 1];
		pager.innerHTML =
			(prev ? '<a class="prev" href="' + href(prev[0]) + '"><small>Previous</small>' + prev[1] + "</a>" : "") +
			(next ? '<a class="next" href="' + href(next[0]) + '"><small>Next</small>' + next[1] + "</a>" : "");
		doc.appendChild(pager);
		var foot = document.createElement("p");
		foot.className = "footer";
		foot.innerHTML = 'Branch is open source (MIT). <a href="' + REPO + '">Source on GitHub</a>.';
		doc.appendChild(foot);
	}

	// Luau highlighting for <pre><code>
	var KEYWORDS = /^(local|function|end|if|then|else|elseif|return|for|in|do|while|repeat|until|not|and|or|nil|true|false|self|break|continue|type|export)$/;
	var TOKEN = /(--\[\[[\s\S]*?\]\]|--[^\n]*)|("(?:\\.|[^"\\\n])*"|'(?:\\.|[^'\\\n])*'|`(?:\\.|[^`\\])*`|\[\[[\s\S]*?\]\])|(\b\d+(?:\.\d+)?\b)|([A-Za-z_][A-Za-z0-9_]*)/g;
	document.querySelectorAll("pre > code").forEach(function (code) {
		if (code.classList.contains("plain")) { return; }
		var text = code.textContent;
		var out = "", last = 0, match;
		TOKEN.lastIndex = 0;
		while ((match = TOKEN.exec(text))) {
			out += escape(text.slice(last, match.index));
			if (match[1]) { out += '<span class="c">' + escape(match[1]) + "</span>"; }
			else if (match[2]) { out += '<span class="s">' + escape(match[2]) + "</span>"; }
			else if (match[3]) { out += '<span class="n">' + match[3] + "</span>"; }
			else if (KEYWORDS.test(match[4])) { out += '<span class="k">' + match[4] + "</span>"; }
			else { out += escape(match[4]); }
			last = TOKEN.lastIndex;
		}
		code.innerHTML = out + escape(text.slice(last));
	});

	// copy buttons
	document.querySelectorAll("pre").forEach(function (pre) {
		var button = document.createElement("button");
		button.type = "button";
		button.className = "copy";
		button.textContent = "Copy";
		button.addEventListener("click", function () {
			var text = pre.querySelector("code") ? pre.querySelector("code").textContent : pre.textContent;
			var done = function () { button.textContent = "Copied"; setTimeout(function () { button.textContent = "Copy"; }, 1400); };
			if (navigator.clipboard && navigator.clipboard.writeText) {
				navigator.clipboard.writeText(text).then(done, function () {});
			}
		});
		pre.appendChild(button);
	});

	// ---------------------------------------------------------------- search
	// The index is built in the browser from the pages themselves (one entry
	// per section), the first time search opens.
	var index = null, loading = null;
	function buildIndex() {
		if (loading) { return loading; }
		var pages = flat.filter(function (page) { return page[0] !== "benchmarks"; });
		loading = Promise.all(pages.map(function (page) {
			return fetch(href(page[0])).then(function (r) { return r.ok ? r.text() : ""; }).then(function (html) {
				var parsed = new DOMParser().parseFromString(html, "text/html");
				var main = parsed.querySelector(".doc");
				if (!main) { return []; }
				// words of neighbouring elements must not run together in snippets
				main.querySelectorAll(".how, .copy").forEach(function (n) { n.remove(); });
				main.querySelectorAll("p, li, td, th, h3, h4, article, div, code, span").forEach(function (n) { n.insertAdjacentText("beforeend", " "); });
				var list = nameHeadings(parsed);
				var entries = [];
				var intro = main.querySelector(".lead");
				entries.push({ page: page[1], key: page[0], id: "", title: page[1], text: intro ? intro.textContent : "" });
				list.forEach(function (item) {
					var text = "";
					var node = item.node.nextElementSibling;
					if (!node && item.node.parentElement.classList.contains("api")) { node = item.node.parentElement.firstElementChild; }
					while (node && !/^H[123]$/.test(node.tagName) && text.length < 600) {
						if (node.tagName !== "PRE") { text += " " + node.textContent; }
						node = node.nextElementSibling;
					}
					if (item.node.parentElement.classList.contains("api")) {
						text = item.node.parentElement.textContent;
					}
					var title = item.node.cloneNode(true);
					title.querySelectorAll(".tag, .new, .auto, .studio").forEach(function (n) { n.remove(); });
					entries.push({ page: page[1], key: page[0], id: item.id, title: title.textContent.trim(), text: text.replace(/\s+/g, " ").trim() });
				});
				return entries;
			}).catch(function () { return []; });
		})).then(function (all) {
			index = [].concat.apply([], all);
			return index;
		});
		return loading;
	}

	function search(query) {
		var terms = query.toLowerCase().split(/\s+/).filter(Boolean);
		if (!terms.length || !index) { return []; }
		var scored = [];
		index.forEach(function (entry) {
			var title = entry.title.toLowerCase(), text = entry.text.toLowerCase(), page = entry.page.toLowerCase();
			var score = 0;
			for (var i = 0; i < terms.length; i++) {
				var term = terms[i];
				var inTitle = title.indexOf(term), inText = text.indexOf(term);
				if (inTitle < 0 && inText < 0 && page.indexOf(term) < 0) { return; }
				if (inTitle === 0) { score += 12; } else if (inTitle > 0) { score += 8; }
				if (inText >= 0) { score += 2; }
				if (page.indexOf(term) >= 0) { score += 1; }
			}
			if (!entry.id) { score += 1; }
			scored.push({ entry: entry, score: score });
		});
		scored.sort(function (a, b) { return b.score - a.score; });
		return scored.slice(0, 30).map(function (item) { return item.entry; });
	}

	function highlight(text, terms) {
		var safe = escape(text);
		terms.forEach(function (term) {
			if (term.length < 2) { return; }
			safe = safe.replace(new RegExp("(" + term.replace(/[.*+?^${}()|[\]\\]/g, "\\$&") + ")", "ig"), "<mark>$1</mark>");
		});
		return safe;
	}

	function snippet(text, terms) {
		var lower = text.toLowerCase(), at = -1;
		for (var i = 0; i < terms.length && at < 0; i++) { at = lower.indexOf(terms[i]); }
		var start = Math.max(0, at - 50);
		var cut = text.slice(start, start + 150);
		return (start > 0 ? "…" : "") + cut + (start + 150 < text.length ? "…" : "");
	}

	var dialog = document.createElement("div");
	dialog.className = "search";
	dialog.hidden = true;
	dialog.innerHTML =
		'<div class="search-box" role="dialog" aria-modal="true" aria-label="Search the docs">' +
		'<div class="search-field"><svg viewBox="0 0 24 24" aria-hidden="true"><circle cx="10.5" cy="10.5" r="6.5"/><path d="M15.5 15.5 20 20"/></svg>' +
		'<input type="search" placeholder="Search: FireFrom, migrations, Rate..." aria-label="Search" autocomplete="off" spellcheck="false">' +
		'<button type="button" class="search-close" aria-label="Close">Esc</button></div>' +
		'<ol class="search-results" role="listbox"></ol>' +
		'<p class="search-hint">↑ ↓ to move, Enter to open</p></div>';
	body.appendChild(dialog);
	var input = dialog.querySelector("input");
	var results = dialog.querySelector(".search-results");
	var selected = 0, shown = [];

	function render() {
		var query = input.value.trim();
		if (!index) {
			results.innerHTML = '<li class="empty">Loading the docs…</li>';
			return;
		}
		if (!query) {
			results.innerHTML = '<li class="empty">Type to search every page of the docs.</li>';
			shown = [];
			return;
		}
		var terms = query.toLowerCase().split(/\s+/).filter(Boolean);
		shown = search(query);
		selected = 0;
		if (!shown.length) {
			results.innerHTML = '<li class="empty">Nothing found for “' + escape(query) + '”.</li>';
			return;
		}
		results.innerHTML = shown.map(function (entry, i) {
			return '<li role="option"' + (i === 0 ? ' aria-selected="true"' : "") + '><a href="' + href(entry.key) + (entry.id ? "#" + entry.id : "") + '">' +
				'<small>' + escape(entry.page) + "</small>" +
				"<b>" + highlight(entry.title, terms) + "</b>" +
				(entry.text ? "<span>" + highlight(snippet(entry.text, terms), terms) + "</span>" : "") + "</a></li>";
		}).join("");
	}

	function move(delta) {
		var items = results.querySelectorAll("li[role=option]");
		if (!items.length) { return; }
		items[selected].removeAttribute("aria-selected");
		selected = (selected + delta + items.length) % items.length;
		items[selected].setAttribute("aria-selected", "true");
		items[selected].scrollIntoView({ block: "nearest" });
	}

	var opener = null;
	function openSearch() {
		opener = document.activeElement;
		dialog.hidden = false;
		body.classList.add("searching");
		input.focus();
		input.select();
		render();
		buildIndex().then(render);
	}
	function closeSearch() {
		dialog.hidden = true;
		body.classList.remove("searching");
		if (opener && opener.focus) { opener.focus(); }
	}

	top.querySelector(".search-open").addEventListener("click", openSearch);
	dialog.querySelector(".search-close").addEventListener("click", closeSearch);
	dialog.addEventListener("mousedown", function (event) { if (event.target === dialog) { closeSearch(); } });
	input.addEventListener("input", render);
	input.addEventListener("keydown", function (event) {
		if (event.key === "ArrowDown") { event.preventDefault(); move(1); }
		else if (event.key === "ArrowUp") { event.preventDefault(); move(-1); }
		else if (event.key === "Enter") {
			var link = results.querySelector("li[aria-selected] a");
			if (link) { event.preventDefault(); closeSearch(); location.href = link.href; }
		}
	});
	results.addEventListener("click", function (event) { if (event.target.closest("a")) { closeSearch(); } });
	document.addEventListener("keydown", function (event) {
		if ((event.ctrlKey || event.metaKey) && event.key.toLowerCase() === "k") {
			event.preventDefault();
			if (dialog.hidden) { openSearch(); } else { closeSearch(); }
		} else if (event.key === "Escape" && !dialog.hidden) {
			closeSearch();
		} else if (event.key === "/" && dialog.hidden && !/INPUT|TEXTAREA/.test(document.activeElement.tagName)) {
			event.preventDefault();
			openSearch();
		}
	});
})();
