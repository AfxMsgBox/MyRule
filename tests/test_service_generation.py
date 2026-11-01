"""Generate/migrate services under fake /etc, never touching host services."""
import unittest
import test_scripts


class ServiceGenerationTests(unittest.TestCase):
    setUp = test_scripts.ShellTests.setUp
    command = test_scripts.ShellTests.command
    file = test_scripts.ShellTests.file
    run_shell = test_scripts.ShellTests.run_shell
    assert_ok = test_scripts.ShellTests.assert_ok

    def body(self, name):
        s = test_scripts.function_source(test_scripts.ROOT/('sh/migrate-legacy.sh' if name.startswith('mp_migrate_') else 'sh/common.sh'), name)
        s = s.replace('"/etc/', '"$TEST_ROOT/etc/').replace(' /etc/', ' "$TEST_ROOT"/etc/')
        if name == 'mp_sync_etc_files':
            s=s.replace('    sh \"$MP_INST_DIR/sh/migrate-legacy.sh\" || return 1', '    :')
        return s

    def migrate(self):
        self.command('systemctl', 'echo "$*" >> "$TEST_ROOT/actions"\n')
        return self.run_shell(self.body('mp_migrate_legacy_core')+'\nmp_migrate_legacy_core')

    def test_migration_stops_owned_route_unit_and_removes_old_copies(self):
        unit = self.file('etc/systemd/system/proxy_route.service',
                         'Documentation=https://github.com/AfxMsgBox/MyRule\n'
                         f'ExecStart=/bin/sh {self.root}/sh/setup-fake-ip-route.sh --watch\n')
        link = self.root/'etc/systemd/system/multi-user.target.wants/proxy_route.service'
        link.parent.mkdir()
        link.symlink_to('../proxy_route.service')
        old = self.file('sh/setup-fake-ip-route.sh', '# auto-route:false old\n')
        copy = self.file('sh/etc/systemd/system/proxy_core.service',
                         'Documentation=https://github.com/AfxMsgBox/MyRule\n')
        for name in ('agh', 'proxy_route'):
            self.file(f'sh/etc/systemd/system/{name}.service',
                      'Documentation=https://github.com/AfxMsgBox/MyRule\n')
        for name in ('agh', 'proxy_core'):
            self.file(f'sh/etc/init.d/{name}', f'USE_PROCD=1\nMP_INST_DIR={self.root}\n')
        self.assert_ok(self.migrate())
        for p in (unit, link, old, copy):self.assertFalse(p.exists())
        self.assertFalse((self.root/'sh/etc').exists())
        self.assertEqual((self.root/'actions').read_text().splitlines(), ['stop proxy_route.service'])
        self.assert_ok(self.migrate())

    def test_foreign_route_unit_is_not_stopped_or_removed(self):
        unit = self.file('etc/systemd/system/proxy_route.service', 'foreign\n')
        self.assertNotEqual(self.migrate().returncode, 0)
        self.assertEqual(unit.read_text(), 'foreign\n')
        self.assertFalse((self.root/'actions').exists())
        unit.unlink()
        foreign = self.file('foreign', 'foreign\n')
        unit.symlink_to(foreign)
        self.assertNotEqual(self.migrate().returncode, 0)
        self.assertTrue(unit.is_symlink())

    def test_historical_shell_unit_matches_install_assignment_without_eval(self):
        template = ('Documentation=https://github.com/AfxMsgBox/MyRule\n'
                    "ExecStart=/bin/sh -c 'MP_INST_DIR=INSTALL; export MP_INST_DIR; "
                    'exec /bin/sh "$MP_INST_DIR/sh/setup-fake-ip-route.sh" --watch\'\n')
        unit = self.file('etc/systemd/system/proxy_route.service',
                         template.replace('INSTALL', str(self.root)))
        self.assert_ok(self.migrate())
        self.assertFalse(unit.exists())
        unit.write_text(template.replace('INSTALL', '/other/install'))
        (self.root/'actions').unlink()
        self.assertNotEqual(self.migrate().returncode, 0)
        self.assertTrue(unit.exists())
        self.assertFalse((self.root/'actions').exists())
        # An expected path appearing only in a comment does not prove ownership.
        unit.write_text('Documentation=https://github.com/AfxMsgBox/MyRule\n'
                        f'# {self.root}/sh/setup-fake-ip-route.sh\nExecStart=/bin/false\n')
        self.assertNotEqual(self.migrate().returncode, 0)
        self.assertTrue(unit.exists())

    def sync(self, platform):
        return self.run_shell('mp_detect_os() { echo '+platform+'; }\n'
             'mp_require_route_tools() { :; }\nmp_migrate_legacy_routes() { :; }\n'
             'mp_migrate_legacy_core() { :; }\nsystemctl() { :; }\n'+
             self.body('mp_sync_etc_files')+'\nmp_sync_etc_files always')

    def test_both_platforms_generate_files_with_correct_paths_and_permissions(self):
        for platform,rel,mode in [('systemd','systemd/system/proxy_core.service',0o644),
                                  ('openwrt','init.d/proxy_core',0o755)]:
            self.assert_ok(self.sync(platform))
            path=self.root/'etc'/rel
            self.assertEqual(path.stat().st_mode & 0o777, mode)
            self.assertIn(str(self.root), path.read_text())
            self.assertIn('start.sh', path.read_text())
            self.assertFalse((self.root/'sh/etc').exists())

    def test_permission_failure_preserves_old_service(self):
        path=self.file('etc/systemd/system/proxy_core.service', 'old\n')
        self.command('chmod','exit 1\n')
        self.assertNotEqual(self.sync('systemd').returncode,0)
        self.assertEqual(path.read_text(),'old\n')

    def test_start_download_failure_preserves_previous_launcher(self):
        original=self.root/'core/start.sh'
        before=original.read_bytes()
        self.assertNotEqual(self.run_shell('download_file() { return 1; }\nmp_sync_core_start').returncode,0)
        self.assertEqual(original.read_bytes(),before)
        self.assertFalse(list(original.parent.glob('.start.*')))
