timbre_sources = [
  'main.vala',
  'application.vala',
  'window.vala',
]

timbre_deps = [
  config_dep,
  dependency('gtk4'),
  dependency('libadwaita-1', version: '>= 1.4'),
]

timbre_sources += gnome.compile_resources('timbre-resources',
  'timbre.gresource.xml',
  c_name: 'timbre'
)

executable('timbre', timbre_sources,
  dependencies: timbre_deps,
  include_directories: config_inc,
       install: true,
)
