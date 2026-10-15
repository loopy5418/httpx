// Helper script to refresh the page when it is modified
(function () {
  if (!window.EventSource) return;
  var source = new EventSource("/__httpx/live");
  source.addEventListener("reload", function () {
    window.location.reload();
  });
  source.addEventListener("css", function () {
    // Stylesheets can be swapped without a full reload.
    var links = document.querySelectorAll('link[rel="stylesheet"]');
    for (var i = 0; i < links.length; i++) {
      var url = new URL(links[i].href);
      url.searchParams.set("_reload", Date.now());
      links[i].href = url.toString();
    }
  });
})();
