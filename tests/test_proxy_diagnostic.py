"""Isolated proxy diagnostic: no real network or user credentials required."""
import base64
import contextlib
import copy
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch


SCRIPT = Path(__file__).resolve().parents[1] / 'sh/test-proxy.py'
spec = importlib.util.spec_from_file_location('proxy_diagnostic', SCRIPT)
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)
NODE = dict(name='test node', type='vmess', server='node.example.test', port=12345,
            uuid='00000000-0000-4000-8000-000000000001', alterId=0, cipher='auto',
            tls=True, servername='tls.example.test', network='ws',
            **{'ws-opts': {'path': '/path', 'headers': {'Host': 'ws.example.test'}}})

FAKE_CORE = r'''
import http.server,json,sys,pathlib,urllib.parse
config=json.loads(pathlib.Path(sys.argv[sys.argv.index('-f')+1]).read_text())
if config['proxies'][0]['server']=='startup-fail.test':sys.exit(7)
class Handler(http.server.BaseHTTPRequestHandler):
 last_url=''
 def log_message(self,*args):pass
 def do_GET(self):
  if self.headers.get('Authorization')!='Bearer '+config['secret']:
   self.send_response(401);self.end_headers();return
  code=200
  if self.path=='/version': data={'version':'test'}
  elif self.path.startswith('/dns/query?'):
   data={'Status':0,'Answer':[{'type':1,'data':'203.0.113.10'}]}
  elif self.path.startswith('/proxies/diagnostic/delay?'):
   Handler.last_url=urllib.parse.parse_qs(urllib.parse.urlsplit(self.path).query)['url'][0]
   if config['hosts']:data={'delay':123}
   else:code=503;data={'message':'failed'}
  elif self.path=='/proxies/diagnostic':
   data={'extra':{Handler.last_url:{'alive':config['proxies'][0]['server']!='http-status-fail.test'}}}
  else:code=404;data={}
  self.send_response(code);self.end_headers();self.wfile.write(json.dumps(data).encode())
host,port=config['external-controller'].split(':')
http.server.HTTPServer((host,int(port)),Handler).serve_forever()
'''


class ProxyDiagnosticTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.binary = self.root / 'mihomo'
        self.binary.write_text('#!' + sys.executable + '\n' + FAKE_CORE)
        self.binary.chmod(0o700)
        self.source = self.root / 'nodes.json'
        self.source.write_text(json.dumps({'proxies': [NODE]}))

    def settings(self):
        s = copy.deepcopy(probe.DEFAULTS)
        s.update(source=str(self.source), mihomo=str(self.binary), timeout=1,
                 dns=['223.5.5.5'])
        return s

    def test_pinned_ip_preserves_hostname_tls_and_transport(self):
        original = copy.deepcopy(NODE)
        cfg = probe.isolated_config(NODE, '223.5.5.5', 1234, 'secret', '203.0.113.10')
        self.assertEqual(NODE, original)
        self.assertEqual(cfg['hosts'], {NODE['server']: '203.0.113.10'})
        self.assertEqual(cfg['proxies'][0], {**NODE, 'name': 'diagnostic'})
        self.assertFalse(cfg['tun']['enable'])
        self.assertFalse(cfg['dns']['use-system-hosts'])
        self.assertNotIn('listen', cfg['dns'])
        self.assertNotIn('proxy-providers', cfg)
        for key in ('port', 'socks-port', 'mixed-port', 'redir-port', 'tproxy-port'):
            self.assertEqual(cfg[key], 0)
        self.assertEqual(cfg['external-controller'], '127.0.0.1:1234')

    def test_literal_ip_cannot_be_misattributed_to_another_ip(self):
        with self.assertRaises(probe.DiagnosticError):
            probe.isolated_config({**NODE, 'server':'203.0.113.1'}, '223.5.5.5', 1234,
                                  'secret', '203.0.113.2')

    def test_real_child_api_and_cleanup_on_success_and_exception(self):
        for should_raise in (False, True):
            core = probe.Core(str(self.binary), NODE, '223.5.5.5', 1, '203.0.113.10')
            try:
                with core:
                    work = Path(core.work.name)
                    self.assertEqual(work.stat().st_mode & 0o777, 0o700)
                    self.assertEqual((work/'config.json').stat().st_mode & 0o777, 0o600)
                    self.assertEqual((work/'core.log').stat().st_mode & 0o777, 0o600)
                    self.assertEqual(core.resolve(), ['203.0.113.10'])
                    self.assertEqual(core.probe(probe.DEFAULTS['url']), (True, '123 ms'))
                    if should_raise:
                        raise KeyboardInterrupt
            except KeyboardInterrupt:
                pass
            self.assertIsNotNone(core.process.poll())
            self.assertFalse(work.exists())

    def test_startup_failure_cleanup(self):
        core = probe.Core(str(self.binary), {**NODE, 'server':'startup-fail.test'}, '223.5.5.5', 1)
        with self.assertRaises(probe.DiagnosticError):
            with core:
                self.fail('must not start')
        self.assertFalse(Path(core.work.name).exists())
        self.assertIsNotNone(core.process.poll())

    def test_failed_protocol_is_not_reported_as_tcp_success(self):
        with probe.Core(str(self.binary), NODE, '223.5.5.5', 1) as core:
            ok, detail = core.probe(probe.DEFAULTS['url'])
        self.assertFalse(ok)
        self.assertIn('503', detail)

    def test_positive_delay_does_not_prove_expected_http_status(self):
        node = {**NODE, 'server':'http-status-fail.test'}
        with probe.Core(str(self.binary), node, '223.5.5.5', 1, '203.0.113.10') as core:
            ok, detail = core.probe(probe.DEFAULTS['url'])
        self.assertFalse(ok)
        self.assertIn('未确认', detail)

    def test_full_diagnosis_tries_dns_and_pinned_ip_without_secrets(self):
        with patch.object(probe, 'tcp_probe', return_value='TCP OK'), \
                contextlib.redirect_stdout(io.StringIO()) as out:
            self.assertEqual(probe.diagnose(self.settings(), NODE), 0)
        text = out.getvalue()
        self.assertIn('失败 API 503', text)
        self.assertIn('固定 IP | 203.0.113.10 | TCP OK | 123 ms', text)
        self.assertNotIn(NODE['uuid'], text)

    def test_config_priority_and_private_atomic_save(self):
        path = self.root / 'private.conf'
        probe.save_config(path, dict(source=str(self.source), node='config node', timeout=3,
                                     dns=['119.29.29.29']))
        self.assertEqual(path.stat().st_mode & 0o777, 0o600)
        s, interactive, chosen = probe.arguments(['--config', str(path), '--node', 'CLI node', '--dns', '223.5.5.5'])
        self.assertFalse(interactive)
        self.assertEqual(s['node'], 'CLI node')
        self.assertEqual(s['timeout'], 3)
        self.assertEqual(s['dns'], ['223.5.5.5'])
        self.assertEqual(chosen, path)
        with patch.object(probe, 'DEFAULT_CONFIG', path):
            s, interactive, chosen = probe.arguments([])
            self.assertTrue(interactive)
            self.assertEqual(s['node'], 'config node')
            s, interactive, chosen = probe.arguments(['--config'])
            self.assertFalse(interactive)
            self.assertEqual(chosen, path)
        link = self.root / 'link'
        link.symlink_to(path)
        with self.assertRaises(probe.DiagnosticError):
            probe.save_config(link, {})
        self.assertEqual(probe.read_json(path)['timeout'], 3)

    def test_interactive_override_and_save_prompt(self):
        with patch.object(probe, 'DEFAULT_CONFIG', self.root/'default.conf'), \
                patch('builtins.input', side_effect=[str(self.source), str(self.binary), '', '', '', '2', '1', 'y']), \
                patch.object(probe, 'diagnose', return_value=0) as diagnose, \
                contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(probe.main([]), 0)
        saved = probe.read_json(self.root/'default.conf')
        self.assertEqual(saved['node'], NODE['name'])
        self.assertEqual(saved['timeout'], 2)
        self.assertEqual(diagnose.call_args.args[0]['timeout'], 2)

    def test_cli_missing_required_input_does_not_prompt(self):
        with patch('builtins.input', side_effect=AssertionError('must not prompt')), \
                contextlib.redirect_stderr(io.StringIO()) as err:
            self.assertEqual(probe.main(['--mihomo', str(self.binary)]), 2)
        self.assertIn('--source', err.getvalue())

    def test_native_json_and_vmess_sources(self):
        self.assertEqual(probe.select_node(probe.read_nodes(str(self.source), 1), ''), NODE)
        v = dict(ps='vmess test', add='node.example.test', port='12345', id=NODE['uuid'],
                 aid=0, net='ws', tls='tls', sni='tls.example.test', path='/path', host='ws.example.test')
        line = 'vmess://' + base64.b64encode(json.dumps(v).encode()).decode()
        for data in (line, base64.b64encode(line.encode()).decode()):
            self.source.write_text(data)
            result = probe.select_node(probe.read_nodes(str(self.source), 1), 'vmess')
            self.assertEqual(result['server'], NODE['server'])
            self.assertEqual(result['servername'], NODE['servername'])
            self.assertEqual(result['ws-opts'], NODE['ws-opts'])
            self.assertEqual(result['port'], NODE['port'])

    def test_ambiguous_and_unsupported_nodes_rejected(self):
        with self.assertRaises(probe.DiagnosticError):
            probe.select_node([NODE, {**NODE, 'name':'test node 2'}], 'test')
        with self.assertRaises(probe.DiagnosticError):
            probe.select_node([{'name':'mcp', '_vmess':{'net':'kcp'}}], '')
        for node in ({**NODE, 'dialer-proxy':'some-other-proxy'}, {**NODE, 'port':0}):
            with self.assertRaises(probe.DiagnosticError):
                probe.select_node([node], '')

    def test_invalid_configuration_and_source_safe_errors(self):
        for field, bad in [('timeout', 31), ('timeout', True), ('dns', []), ('dns', '223.5.5.5'),
                           ('ip', ['not-ip']), ('url', 'http://example.com'),
                           ('url', 'https://user:secret@example.com')]:
            with self.subTest(field=field, value=bad), self.assertRaises(probe.DiagnosticError):
                probe.validate({**self.settings(), field:bad})
        self.source.write_text('proxies: [password: should-not-leak]')
        with self.assertRaises(probe.DiagnosticError) as error:
            probe.read_nodes(str(self.source), 1)
        self.assertNotIn('should-not-leak', str(error.exception))

    def test_help_works_without_mihomo(self):
        r = subprocess.run([sys.executable, '-I', '-S', str(SCRIPT), '--help'], capture_output=True, text=True)
        self.assertEqual(r.returncode, 0)
        for arg in ('--config', '--source', '--node', '--mihomo', '--dns', '--ip', '--url', '--timeout'):
            self.assertIn(arg, r.stdout)


if __name__ == '__main__':
    unittest.main()
