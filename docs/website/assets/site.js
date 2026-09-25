// Branch docs: shared chrome for every page (top bar, sidebar, pager),
// Luau highlighting and copy buttons. Pages set data-root (path to the
// site root) and data-page (their key in NAV) on <body>.
(function () {
	var NAV = [
		{ group: "start", title: "Start", pages: [
			["index", "Home"],
			["getting-started", "Getting started"],
			["features", "Unique features"],
		] },
		{ group: "guide", title: "Guides", pages: [
			["guide/segments", "Segments"],
			["guide/data", "Player data"],
			["guide/network", "Networking"],
			["guide/features", "Using the features"],
			["guide/studio", "Branch Studio"],
			["guide/migrating", "Moving from Branch 1"],
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

	// top bar
	var top = document.createElement("header");
	top.className = "top";
	top.innerHTML =
		'<a class="brand" href="' + href("index") + '"><img src="' + root + 'assets/mark.png" alt="">Branch</a>' +
		'<span class="ver">v2.0.0</span>' +
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
	if (side) {
		var html = "";
		NAV.forEach(function (group) {
			html += '<div class="navgroup"><h4><b>' + group.group + "</b>/ " + group.title + "</h4><ol>";
			group.pages.forEach(function (page) {
				flat.push(page);
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

	// previous / next
	var doc = document.querySelector(".doc");
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
	var escape = function (text) { return text.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;"); };
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
})();
