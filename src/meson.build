fs = import('fs')
gnome = import('gnome')

cargo = find_program('cargo', required: true)
blueprint_compiler = find_program('blueprint-compiler', required: true)

cargo_options = [
  '--manifest-path', meson.project_source_root() / 'subprojects/libtimbre/Cargo.toml',
]
cargo_target_dir = meson.project_source_root() / 'subprojects/libtimbre/target'

if get_option('buildtype') == 'release'
  cargo_options += ['--release']
  cargo_out_dir = cargo_target_dir / 'release'
else
  cargo_out_dir = cargo_target_dir / 'debug'
endif

libtimbre_target = custom_target(
  'cargo-build-libtimbre',
  build_by_default: true,
  build_always_stale: true,
  output: 'libtimbre.so',
  command: [
    'sh',
    '-c', '@0@ build @1@ && cp @2@/libtimbre.so @OUTPUT@'.format(cargo.full_path(), ' '.join(cargo_options), cargo_out_dir),
  ],
)

libtimbre_dep = declare_dependency(
  sources: libtimbre_target,
  link_args: [
    meson.current_build_dir() / 'libtimbre.so',
    '-Wl,-rpath,' + meson.current_build_dir(),
  ],
  include_directories: include_directories('.'),
)

subdir('widgets')
subdir('utils')
subdir('pages')
subdir('models')
subdir('services')

blueprints = [
  'window.blp',
] + widgets_blueprints + pages_blueprints

compiled_ui = []
foreach bp : blueprints
  ui_filename = fs.name(fs.replace_suffix(bp, '.ui'))
  compiled_ui += custom_target(
    'blueprint-compile-' + ui_filename,
    input: bp,
    output: ui_filename,
    command: [blueprint_compiler, 'compile', '--output', '@OUTPUT@', '@INPUT@'],
  )
endforeach

timbre_resources = gnome.compile_resources(
  'timbre-resources',
  'timbre.gresource.xml',
  c_name: 'timbre',
  dependencies: compiled_ui,
)

timbre_sources = [
  'main.vala',
  'application.vala',
  'window.vala',
] + widgets_sources + utils_sources + pages_sources + models_sources + services_sources

timbre_deps = [
  config_dep,
  libtimbre_vapi,
  libtimbre_dep,
  dependency('gtk4'),
  dependency('libadwaita-1', version: '>= 1.4'),
  dependency('gio-2.0'),
  dependency('libsoup-3.0'),
  dependency('json-glib-1.0'),
  dependency('webkitgtk-6.0'),
  meson.get_compiler('c').find_library('m', required: false),
]

executable(
  'timbre',
  timbre_sources,
  timbre_resources,
  dependencies: timbre_deps,
  include_directories: config_inc,
  install: true,
)
