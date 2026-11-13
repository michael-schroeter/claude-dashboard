// Made-up projects for the README pictures. Nothing here comes from real sessions.
(function () {
  const now = Date.now();
  const min = 60 * 1000;
  const session = (id, title, excerpt, minutes, openTurn) => ({
    id, title, excerpt, lastTs: now - minutes * min, openTurn: !!openTurn,
  });
  const project = (name, color, icon, sessions, extra) =>
    Object.assign(
      {
        dir: '-demo-' + name, name, path: '~/Projects/' + name, missing: false, color, icon,
        archived: false, current: false, lastTs: sessions[0].lastTs, sessions,
      },
      extra || {}
    );

  window.DEMO_PROJECTS = [
    project('weather-station', 6, 'cloud', [
      session('a1', 'Add humidity sensor to the dashboard', 'The chart now shows both series. I am running the tests once more.', 1, true),
      session('a2', 'Fix time zone in the export', 'Should the export use local time or UTC?', 25, true),
      session('a3', 'Write the README', 'The README covers setup, usage and removal.', 300),
      session('a4', 'Set up the project', 'Done. The folder structure is in place.', 3000),
    ], { current: true }),
    project('recipe-book', 3, 'book', [
      session('b1', 'Import recipes from a text file', 'All 42 recipes were imported. Three had no title, I named them after their first ingredient.', 90),
      session('b2', 'Shopping list per week', 'The list groups ingredients by shop section.', 1500),
      session('b3', 'Print layout', 'Two recipes fit on one page now.', 4200),
    ]),
    project('garden-plan', 2, 'leaf', [
      session('c1', 'Draw the bed layout', 'The plan is saved as plan.svg. Tomatoes moved to the south side.', 60 * 24 * 3),
      session('c2', 'Watering schedule', 'The schedule skips days with rain in the forecast.', 60 * 24 * 6),
    ]),
    project('travel-notes', 5, 'folder', [
      session('d1', 'Compare the two routes', 'Which of the two should I look at first?', 200, true),
      session('d2', 'Collect the documents', 'All documents are in the folder.', 60 * 24 * 9),
    ]),
    project('home-budget', 1, 'banknote', [
      session('e1', 'Monthly overview', 'The overview for October is ready.', 60 * 24 * 12),
      session('e2', 'Categories for the import', 'Every booking has a category now.', 60 * 24 * 20),
    ]),
  ];
})();
