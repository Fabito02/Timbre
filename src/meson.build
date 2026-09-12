cargo = find_program('cargo', required: true)

cargo_options = ['--manifest-path', meson.project_source_root() / 'subprojects/libtimbre/Cargo.toml']
cargo_target_dir = meson.project_source_root() / 'subprojects/libtimbre/target'

if get_option('buildtype') == 'release'
  cargo_options += ['--release']
  cargo_out_dir = cargo_target_dir / 'release'
else
  cargo_out_dir = cargo_target_dir / 'debug'
endif

libtimbre_target = custom_target('cargo-build-libtimbre',
  build_by_default: true,
  output: 'libtimbre.so',
  command: [
    'sh', '-c',
    '@0@ build @1@ && cp @2@/libtimbre.so @OUTPUT@'.format(
      cargo.full_path(),
      ' '.join(cargo_options),
      cargo_out_dir
    )
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

timbre_sources = [
  'main.vala',
  'application.vala',
  'window.vala',
]

timbre_deps = [
  config_dep,
  libtimbre_vapi,
  libtimbre_dep,
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
