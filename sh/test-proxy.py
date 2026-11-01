#!/usr/bin/env python3
"""用独立 Mihomo 实例比较 DNS、TCP 与代理 HTTPS；Python 3.8+ 标准库。"""
import argparse
import base64
import copy
import ipaddress
import json
import os
from pathlib import Path
import secrets
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid


DEFAULT_CONFIG = Path(__file__).resolve().with_suffix('.conf')
DEFAULTS = dict(source='', node='', mihomo='/etc/proxy/core/mihomo',
                dns=['223.5.5.5', '119.29.29.29', 'https://223.5.5.5/dns-query'],
                ip=[], url='https://www.gstatic.com/generate_204', timeout=8)
DIRECT = urllib.request.build_opener(urllib.request.ProxyHandler({}))


class DiagnosticError(Exception):
    pass


def read_json(path):
    try:
        return json.loads(Path(path).read_text(encoding='utf-8'))
    except (OSError, ValueError):
        raise DiagnosticError('无法读取 JSON 文件或格式错误') from None


def save_config(path, settings):
    path = Path(path)
    if path.is_symlink() or (path.exists() and not path.is_file()):
        raise DiagnosticError('配置路径必须是普通文件，不能是符号链接')
    fd, name = tempfile.mkstemp(prefix='.' + path.name + '.', dir=str(path.parent))
    try:
        with os.fdopen(fd, 'w', encoding='utf-8') as f:
            os.fchmod(f.fileno(), 0o600)
            json.dump(settings, f, ensure_ascii=False, indent=2)
            f.write('\n')
        os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def arguments(argv):
    p = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog='无参数：交互，末尾可保存配置（含订阅凭据，权限 600）。\n'
               '有参数：不交互；优先级为交互 > 命令行 > JSON 配置 > 默认值。\n'
               '仅作 IPv4 诊断，不修改现有服务；0=至少一条完整请求成功，1=全部失败，2=输入/启动错误。')
    p.add_argument('--config', nargs='?', const=str(DEFAULT_CONFIG), metavar='PATH',
                   help='读取 JSON 配置；省略 PATH 用同目录 test-proxy.conf；无参数自动读取该文件')
    p.add_argument('--source', help='必填：v2rayN VMess 订阅 URL/本地文件，或本地 Mihomo JSON；不支持 Clash YAML')
    p.add_argument('--node', help='节点名称或唯一关键词；多节点时必填，无参数向导可按编号选择')
    p.add_argument('--mihomo', help='已有内核路径；默认 /etc/proxy/core/mihomo，不自动安装')
    p.add_argument('--dns', action='append', help='待比较的 DNS，可重复；默认阿里/腾讯 UDP DNS 和阿里 DoH')
    p.add_argument('--ip', action='append', help='额外测试的节点 IPv4，可重复；默认无，DNS 结果会自动加入')
    p.add_argument('--url', help='代理 HTTPS 测试地址；默认 https://www.gstatic.com/generate_204，要求 HTTP 200–299')
    p.add_argument('--timeout', type=int, help='单次 DNS/TCP/代理请求超时秒数；默认 8，允许 1–30')
    args = vars(p.parse_args(argv))
    interactive = not argv
    config = args.pop('config')
    if interactive and DEFAULT_CONFIG.is_file():
        config = str(DEFAULT_CONFIG)
    settings = copy.deepcopy(DEFAULTS)
    if config:
        data = read_json(config)
        if not isinstance(data, dict) or set(data) - set(DEFAULTS):
            raise DiagnosticError('配置必须是 JSON 对象，且只能包含帮助中列出的选项')
        settings.update(data)
    settings.update({k: v for k, v in args.items() if v is not None})
    return settings, interactive, Path(config) if config else DEFAULT_CONFIG


def prompt(label, default, hidden_default=False):
    shown = '已有值' if hidden_default and default else str(default)
    value = input('{} [{}] > '.format(label, shown))
    return value if value else default


def validate(settings):
    for key in ('source', 'node', 'mihomo', 'url'):
        if not isinstance(settings[key], str):
            raise DiagnosticError(key + ' 必须是字符串')
    if not settings['source']:
        raise DiagnosticError('缺少 --source')
    if type(settings['timeout']) is not int or not 1 <= settings['timeout'] <= 30:
        raise DiagnosticError('timeout 必须是 1–30 的整数')
    url = urllib.parse.urlsplit(settings['url'])
    if url.scheme != 'https' or not url.hostname or url.username or url.password:
        raise DiagnosticError('测试地址必须是无用户名/密码的 HTTPS URL')
    for key in ('dns', 'ip'):
        if not isinstance(settings[key], list) or not all(isinstance(x, str) and x for x in settings[key]):
            raise DiagnosticError(key + ' 必须是字符串数组')
    if not settings['dns']:
        raise DiagnosticError('至少需要一个 DNS')
    for server in settings['dns']:
        if '://' in server:
            parsed = urllib.parse.urlsplit(server)
            if parsed.scheme not in ('https', 'tls', 'tcp', 'udp') or not parsed.hostname or parsed.username or parsed.password:
                raise DiagnosticError('DNS 只支持 IP 或 udp/tcp/tls/https 地址')
        else:
            try:
                ipaddress.IPv4Address(server)
            except ValueError:
                raise DiagnosticError('普通 DNS 请填写 IPv4；自定义端口使用 udp://IP:端口') from None
    try:
        for ip in settings['ip']:
            ipaddress.IPv4Address(ip)
    except ValueError:
        raise DiagnosticError('--ip 必须是 IPv4 地址') from None
    binary = shutil.which(os.path.expanduser(settings['mihomo']))
    if not binary:
        raise DiagnosticError('找不到可执行的 Mihomo；请用 --mihomo 指定')
    settings['mihomo'] = str(Path(binary).resolve())


def decode64(text):
    text = ''.join(text.split())
    return base64.b64decode(text + '=' * (-len(text) % 4), altchars=b'-_', validate=True)


def read_nodes(source, timeout):
    try:
        if source.startswith(('http://', 'https://')):
            if not source.startswith('https://'):
                raise DiagnosticError('订阅下载要求 HTTPS')
            request = urllib.request.Request(source, headers={'User-Agent': 'v2rayN'})
            with DIRECT.open(request, timeout=timeout) as response:
                raw = response.read(4 * 1024 * 1024 + 1)
        else:
            with Path(source).expanduser().open('rb') as f:
                raw = f.read(4 * 1024 * 1024 + 1)
        if len(raw) > 4 * 1024 * 1024:
            raise DiagnosticError('节点文件超过 4 MiB')
        text = raw.decode('utf-8-sig').strip()
        if text.startswith(('{', '[')):
            data = json.loads(text)
            nodes = data.get('proxies', [data]) if isinstance(data, dict) else data
        else:
            if not text.startswith('vmess://'):
                text = decode64(text).decode('utf-8')
            nodes = []
            for line in text.splitlines():
                if line.startswith('vmess://'):
                    vmess = json.loads(decode64(line[8:]))
                    nodes.append({'name': vmess.get('ps', vmess.get('add', 'VMess')), '_vmess': vmess})
        if not isinstance(nodes, list) or not nodes or not all(isinstance(n, dict) and isinstance(n.get('name'), str) for n in nodes):
            raise DiagnosticError('未找到有效节点')
        return nodes
    except (OSError, ValueError, KeyError, TypeError):
        raise DiagnosticError('读取订阅失败：请检查网络及格式（VMess 或 Mihomo JSON）') from None


def select_node(nodes, wanted):
    matches = [n for n in nodes if n['name'] == wanted] if wanted else nodes
    if not matches and wanted:
        matches = [n for n in nodes if wanted in n['name']]
    if len(matches) != 1:
        raise DiagnosticError('节点选择匹配 {} 项，请用 --node 指定唯一名称或关键词'.format(len(matches)))
    node = copy.deepcopy(matches[0])
    if '_vmess' in node:
        v = node['_vmess']
        if v.get('net', 'tcp') not in ('tcp', 'ws') or v.get('type', 'none') not in ('', 'none'):
            raise DiagnosticError('VMess 链接仅支持 TCP/WS 无额外伪装；其它类型请提供 Mihomo JSON')
        node = dict(name=node['name'], type='vmess', server=v['add'], port=int(v['port']),
                    uuid=v['id'], alterId=int(v.get('aid', 0)), cipher=v.get('scy') or 'auto',
                    tls=v.get('tls') == 'tls', udp=True)
        if v.get('sni'):
            node['servername'] = v['sni']
        if v.get('net') == 'ws':
            node['network'] = 'ws'
            node['ws-opts'] = {'path': v.get('path') or '/'}
            if v.get('host'):
                node['ws-opts']['headers'] = {'Host': v['host']}
    try:
        if not isinstance(node.get('server'), str) or not node['server']:
            raise ValueError()
        if type(node.get('port')) is not int or not 1 <= node['port'] <= 65535:
            raise ValueError()
        if not node.get('type') or node.get('dialer-proxy'):
            raise ValueError()
        if node['type'] == 'vmess':
            uuid.UUID(node['uuid'])
    except (ValueError, KeyError, TypeError, AttributeError):
        raise DiagnosticError('节点地址、端口或认证参数无效；不支持链式代理') from None
    return node


def isolated_config(node, resolver, port, secret, pinned_ip=None):
    node = copy.deepcopy(node)
    try:
        original_ip = ipaddress.ip_address(node['server'])
    except ValueError:
        original_ip = None
    if pinned_ip and original_ip is not None and str(original_ip) != pinned_ip:
        raise DiagnosticError('节点地址本身是 IP，不能用 hosts 替换；请使用域名节点测试其它 IP')
    node['name'] = 'diagnostic'
    return {
        'mode': 'rule', 'ipv6': False, 'log-level': 'warning',
        'port': 0, 'socks-port': 0, 'mixed-port': 0, 'redir-port': 0, 'tproxy-port': 0,
        'allow-lan': False, 'bind-address': '127.0.0.1',
        'external-controller': '127.0.0.1:' + str(port), 'secret': secret,
        'tun': {'enable': False}, 'profile': {'store-selected': False, 'store-fake-ip': False},
        'hosts': {node['server']: pinned_ip} if pinned_ip else {},
        'dns': {'enable': True, 'ipv6': False, 'enhanced-mode': 'redir-host',
                'use-hosts': True, 'use-system-hosts': False,
                'default-nameserver': ['223.5.5.5', '119.29.29.29'],
                'nameserver': [resolver], 'proxy-server-nameserver': [resolver]},
        'proxies': [node], 'rules': ['MATCH,diagnostic'],
    }


class Core:
    """Own only a child process, loopback API and private temporary directory."""
    def __init__(self, binary, node, resolver, timeout, pinned_ip=None):
        self.binary, self.node, self.resolver = binary, node, resolver
        self.timeout, self.pinned_ip = timeout, pinned_ip
        self.process = self.work = self.log = None
        self.secret = secrets.token_hex(24)

    def api(self, path):
        request = urllib.request.Request(self.base + path, headers={'Authorization': 'Bearer ' + self.secret})
        with DIRECT.open(request, timeout=self.timeout + 2) as response:
            return json.load(response)

    def __enter__(self):
        try:
            self.work = tempfile.TemporaryDirectory(prefix='myrule-probe-')
            with socket.socket() as sock:
                sock.bind(('127.0.0.1', 0))
                port = sock.getsockname()[1]
            self.base = 'http://127.0.0.1:' + str(port)
            config = isolated_config(self.node, self.resolver, port, self.secret, self.pinned_ip)
            path = Path(self.work.name)
            save_config(path / 'config.json', config)
            fd = os.open(str(path / 'core.log'), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            self.log = os.fdopen(fd, 'wb')
            env = {k: v for k, v in os.environ.items() if k.upper() not in
                   ('HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY', 'NO_PROXY', 'CLASH_HOME_DIR', 'CLASH_CONFIG_FILE')}
            self.process = subprocess.Popen([self.binary, '-d', str(path), '-f', str(path / 'config.json')],
                                            stdout=self.log, stderr=self.log, stdin=subprocess.DEVNULL, env=env)
            end = time.monotonic() + 10
            while time.monotonic() < end:
                if self.process.poll() is not None:
                    raise DiagnosticError('临时 Mihomo 启动失败，退出码 ' + str(self.process.returncode))
                try:
                    if self.api('/version').get('version'):
                        return self
                except (OSError, ValueError):
                    pass
                time.sleep(0.1)
            raise DiagnosticError('临时 Mihomo 启动超时或 API 端口被占用')
        except BaseException:
            self.__exit__(None, None, None)
            raise

    def __exit__(self, *_):
        if self.process and self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait()
        if self.log:
            self.log.close()
        if self.work:
            self.work.cleanup()

    def resolve(self):
        data = self.api('/dns/query?' + urllib.parse.urlencode({'name': self.node['server'], 'type': 'A'}))
        if data.get('Status') != 0:
            raise DiagnosticError('DNS RCODE=' + str(data.get('Status')))
        return sorted({str(ipaddress.IPv4Address(r['data'])) for r in data.get('Answer', []) if r.get('type') == 1})

    def probe(self, url):
        query = urllib.parse.urlencode({'url': url, 'timeout': self.timeout * 1000, 'expected': '200-299'})
        try:
            delay = self.api('/proxies/diagnostic/delay?' + query)['delay']
            # Some Mihomo versions return delay even for an unexpected HTTP
            # status; the per-URL alive flag applies the expected-status check.
            state = self.api('/proxies/diagnostic').get('extra', {}).get(url, {})
            if state.get('alive') is not True:
                return False, '未确认 HTTPS 200–299'
            return True, str(delay) + ' ms'
        except urllib.error.HTTPError as exc:
            return False, '失败 API ' + str(exc.code)
        except (OSError, ValueError, KeyError):
            return False, '请求超时/无效响应'


def tcp_probe(ip, port, timeout):
    start = time.monotonic()
    try:
        with socket.create_connection((ip, port), timeout=timeout):
            pass
        return '成功 {:.0f} ms'.format((time.monotonic() - start) * 1000)
    except socket.timeout:
        return '超时'
    except OSError:
        return '连接失败'


def diagnose(settings, node):
    # Resolver display hides any query credentials; subscription/UUID never printed.
    print('节点：{}:{} ({})'.format(node['server'], node['port'], node['type']), flush=True)
    print('来源 | 节点 IPv4 | TCP | 代理 HTTPS', flush=True)
    candidates = set(settings['ip'])
    successes = 0
    for index, resolver in enumerate(settings['dns'], 1):
        display = resolver.split('?', 1)[0].split('#', 1)[0]
        with Core(settings['mihomo'], node, resolver, settings['timeout']) as core:
            try:
                ips = core.resolve()
            except (OSError, ValueError, DiagnosticError):
                ips = []
            candidates.update(ips)
            ok, detail = core.probe(settings['url'])
            successes += ok
            print('DNS {} {} | {} | — | {}'.format(index, display, ','.join(ips) or '无 A 记录/查询失败', detail), flush=True)
    for ip in sorted(candidates):
        tcp = tcp_probe(ip, node['port'], settings['timeout'])
        with Core(settings['mihomo'], node, settings['dns'][0], settings['timeout'], pinned_ip=ip) as core:
            ok, detail = core.probe(settings['url'])
            successes += ok
        print('固定 IP | {} | {} | {}'.format(ip, tcp, detail), flush=True)
    print('结果：{}。临时实例已清理。'.format('至少一条完整代理请求成功' if successes else '所有完整代理请求失败'), flush=True)
    return 0 if successes else 1


def main(argv=None):
    try:
        settings, interactive, config = arguments(sys.argv[1:] if argv is None else argv)
        if interactive:
            settings['source'] = prompt('VMess 订阅 URL 或 JSON/VMess 文件', settings['source'], True)
            settings['mihomo'] = prompt('Mihomo 路径', settings['mihomo'])
            settings['dns'] = str(prompt('DNS（逗号分隔）', ','.join(settings['dns']))).split(',')
            settings['ip'] = [x for x in str(prompt('额外 IPv4（逗号分隔，可空）', ','.join(settings['ip']))).split(',') if x]
            settings['url'] = prompt('测试 HTTPS URL', settings['url'])
            settings['timeout'] = int(prompt('超时秒数', settings['timeout']))
        validate(settings)
        nodes = read_nodes(settings['source'], settings['timeout'])
        if interactive:
            for index, node in enumerate(nodes, 1):
                print('{}: {}'.format(index, node['name']))
            choice = str(prompt('节点编号或名称', settings['node']))
            if choice.isdigit() and 1 <= int(choice) <= len(nodes):
                choice = nodes[int(choice) - 1]['name']
            settings['node'] = choice
        node = select_node(nodes, settings['node'])
        settings['node'] = node['name']
        result = diagnose(settings, node)
        if interactive and input('保存配置（含订阅凭据，权限 600）？[y/N] > ').lower() in ('y', 'yes'):
            save_config(config, settings)
            print('配置已保存：' + str(config))
        return result
    except (DiagnosticError, ValueError, KeyError, TypeError) as exc:
        message = str(exc) if isinstance(exc, DiagnosticError) else '输入或节点格式错误'
        print('错误：' + message, file=sys.stderr)
        return 2
    except OSError:
        print('错误：文件或进程操作失败，请检查路径和权限', file=sys.stderr)
        return 2
    except (KeyboardInterrupt, EOFError):
        print('\n已取消，临时实例已清理。', file=sys.stderr)
        return 130


if __name__ == '__main__':
    def stop(_signum, _frame):
        raise KeyboardInterrupt
    signal.signal(signal.SIGTERM, stop)
    sys.exit(main())
