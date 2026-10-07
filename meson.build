project('singularity-reader', ['vala', 'c'],
  version: '0.1.0',
  meson_version: '>= 0.59.0'
)

i18n = import('i18n')
add_project_arguments('-DGETTEXT_PACKAGE="singularity-reader"', language: 'c')
subdir('po')

gnome = import('gnome')

gtk_dep     = dependency('gtk4')
gee_dep     = dependency('gee-0.8')
cairo_dep   = dependency('cairo')
poppler_dep = dependency('poppler-glib', version: '>= 22.07.0')
m_dep       = meson.get_compiler('c').find_library('m', required: false)

libsingularity_dep = dependency('singularity-1.0',
  fallback: ['libsingularity', 'libsingularity_dep']
)
pdf_engine_dep = subproject('libsingularity').get_variable('libsingularity_pdf_dep')
gnutls_dep = dependency('gnutls')

if not meson.is_subproject() and libsingularity_dep.type_name() == 'internal'
  libsingularity_vapi_dir = join_paths(meson.project_build_root(), 'subprojects', 'libsingularity')
  add_project_arguments(['--vapidir=' + libsingularity_vapi_dir], language: 'vala')
endif

vapi_dir = meson.current_source_dir() / 'vapi'
poppler_args = ['--vapidir', vapi_dir, '--pkg', 'poppler-glib']
if poppler_dep.version().version_compare('>= 24.12.0')
  poppler_args += ['-D', 'POPPLER_TEXT_STYLE']
endif
if poppler_dep.version().version_compare('>= 25.06.0')
  poppler_args += ['-D', 'POPPLER_INK']
endif
if poppler_dep.version().version_compare('>= 25.10.0')
  poppler_args += ['-D', 'POPPLER_DRAW_BELOW']
endif
add_project_arguments(poppler_args, language: 'vala')

subdir('ui')

resources = gnome.compile_resources(
  'singularity-reader-resources',
  'resources/dev.sinty.reader.gresource.xml',
  source_dir: [meson.current_source_dir(), meson.current_build_dir()],
  dependencies: main_ui
)

core_sources = files(
  'src/geometry.vala',
  'src/document.vala',
  'src/annotations.vala',
)

export_sources = files(
  'src/export/zip.vala',
  'src/export/page_layout.vala',
  'src/export/exporter.vala',
  'src/export/text_export.vala',
  'src/export/sheet_export.vala',
  'src/export/slide_export.vala',
)

signing_sources = files(
  'src/signing/signing.c',
  'src/signing/reader-signing.vapi',
  'src/signing/digital_signer.vala',
  'src/signing/cert_encryption.vala',
)

pro_sources = files(
  'src/pro/pro_context.vala',
  'src/pro/inspector_panel.vala',
  'src/pro/tool_panel.vala',
  'src/pro/operations.vala',
  'src/pro/organize_page.vala',
  'src/pro/comment_page.vala',
  'src/pro/forms_page.vala',
  'src/pro/edit_page.vala',
  'src/pro/redact_page.vala',
  'src/pro/protect_page.vala',
  'src/pro/ocr_page.vala',
  'src/pro/optimize_page.vala',
  'src/pro/standards_page.vala',
  'src/pro/bookmarks_page.vala',
  'src/pro/stamps_page.vala',
  'src/pro/measure_page.vala',
  'src/pro/compare_page.vala',
  'src/pro/attachments_page.vala',
  'src/pro/batch_page.vala',
  'src/pro/read_page.vala',
  'src/pro/reflow_view.vala',
  'src/pro/export_page.vala',
  'src/pro/sign_page.vala',
)

app_sources = core_sources + files(
  'src/app.vala',
  'src/cloud_actions.vala',
  'src/window.vala',
  'src/page_widget.vala',
  'src/document_view.vala',
  'src/render_worker.vala',
  'src/hairline_fix.vala',
  'src/sidebar.vala',
  'src/signatures.vala',
  'src/annotation_popover.vala',
) + export_sources + signing_sources + pro_sources + [resources]

app_deps = [gtk_dep, gee_dep, cairo_dep, poppler_dep, m_dep, libsingularity_dep, pdf_engine_dep, gnutls_dep, dependency('zlib'), dependency('libsoup-3.0'), dependency('gmodule-2.0')]

executable('singularity-reader',
  app_sources + files('src/main.vala'),
  dependencies: app_deps,
  link_args: ['-Wl,-z,lazy'],
  install: true
)

executable('singularity-pdf',
  app_sources + files('src/cli/main.vala'),
  dependencies: app_deps,
  link_args: ['-Wl,-z,lazy'],
  install: true
)

shared_module('pdf-thumbnails',
  files('plugin/pdf_thumbnails.vala', 'src/hairline_fix.vala'),
  dependencies: [gtk_dep, gee_dep, cairo_dep, poppler_dep, m_dep, libsingularity_dep, pdf_engine_dep, dependency('libpeas-2')],
  install: true,
  install_dir: get_option('libdir') / 'singularity' / 'plugins' / 'pdf-thumbnails'
)
install_data('plugin/pdf-thumbnails.plugin',
  install_dir: get_option('libdir') / 'singularity' / 'plugins' / 'pdf-thumbnails'
)

reader_test = executable('reader-test',
  core_sources + files('src/hairline_fix.vala', 'tests/reader_test.vala'),
  dependencies: [gee_dep, cairo_dep, poppler_dep, m_dep, pdf_engine_dep, dependency('gio-2.0'), dependency('gmodule-2.0')],
  vala_args: ['--pkg', 'cairo', '--pkg', 'posix'],
)
test('reader', reader_test)

signature_test = executable('signature-test',
  files('tests/signature_test.vala', 'src/signatures.vala'),
  dependencies: [gtk_dep, gee_dep, cairo_dep, m_dep, libsingularity_dep],
)
test('signature', signature_test)

install_data('data/dev.sinty.reader.desktop',
  install_dir: get_option('datadir') / 'applications'
)

install_data('data/dev.sinty.reader.gschema.xml',
  install_dir: get_option('datadir') / 'glib-2.0' / 'schemas'
)

install_data('data/dev.sinty.reader.json',
  install_dir: get_option('datadir') / 'singularity' / 'app-settings'
)

install_data('data/icons/dev.sinty.reader.svg',
  install_dir: get_option('datadir') / 'icons' / 'hicolor' / 'scalable' / 'apps'
)

export_test = executable('export-test',
  export_sources + files('tests/export_test.vala'),
  dependencies: [gtk_dep, gee_dep, cairo_dep, poppler_dep, m_dep, dependency('gdk-pixbuf-2.0'), dependency('zlib')],
  vala_args: ['--pkg', 'cairo', '--pkg', 'posix'],
)
test('export', export_test, env: ['TMPDIR=' + meson.current_build_dir()], timeout: 120)

signing_test = executable('signing-test',
  signing_sources + files('tests/signing_test.vala'),
  dependencies: [gee_dep, cairo_dep, m_dep, pdf_engine_dep, gnutls_dep, dependency('gio-2.0')],
  vala_args: ['--pkg', 'cairo'],
)
test('signing', signing_test, timeout: 180)

pro_test = executable('pro-test',
  app_sources + files('tests/pro_test.vala'),
  dependencies: app_deps,
  vala_args: ['--pkg', 'cairo'],
)
test('pro', pro_test, env: ['TMPDIR=' + meson.current_build_dir(), 'GSETTINGS_BACKEND=memory', 'LANGUAGE=en', 'LC_ALL=C.UTF-8'], timeout: 300)

cert_encryption_test = executable('cert-encryption-test',
  signing_sources + files('tests/cert_encryption_test.vala'),
  dependencies: [gee_dep, cairo_dep, m_dep, pdf_engine_dep, gnutls_dep, dependency('gio-2.0')],
  vala_args: ['--pkg', 'cairo'],
)
test('cert-encryption', cert_encryption_test, timeout: 120)
