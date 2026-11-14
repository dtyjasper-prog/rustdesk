// PhoneKB relay: the phone keyboard talks to the tablet over the local network
// (phone hotspot or the same Wi-Fi), and the tablet feeds the keys / mouse into
// its own RustDesk session with the PC. So only the tablet needs Tailscale.
//
// Protocol: TCP, one JSON object per line.
//   tablet -> phone  {"t":"hello","name":..,"peer":..,"id":..}   right after connect
//   phone  -> tablet {"t":"auth","pin":"123456"}
//   tablet -> phone  {"t":"ok"} | {"t":"badpin"}
//   phone  -> tablet {"t":"k","u":usbHid,"l":lockModes,"d":down}
//                    {"t":"m","m":{mouse json for sessionSendMouse}}
//                    {"t":"s","v":"text"}  {"t":"cad"}  {"t":"lock"}  {"t":"p"}
//   tablet -> phone  {"t":"p"}  (pong)
//
// A 6-digit pairing PIN (shown on the tablet) keeps others on the same network
// from typing into the PC.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../common.dart';
import '../models/platform_model.dart';

const kPhoneKbRelayPort = 21290;
const _kPinOpt = 'phonekb-relay-pin';
const _kIdOpt = 'phonekb-relay-id';

String _randomDigits(int n) {
  final r = Random.secure();
  return List.generate(n, (_) => r.nextInt(10)).join();
}

// ===========================================================================
// Tablet side
// ===========================================================================

/// What the tablet does with what the phone sends. Default: feed its RustDesk session.
class RelaySink {
  void Function(int usb, int lockModes, bool down) key;
  void Function(Map<String, dynamic> m) mouse;
  void Function(String v) text;
  void Function() ctrlAltDel;
  void Function() lockScreen;
  void Function(String msg, Duration d) toast;
  RelaySink(
      {required this.key,
      required this.mouse,
      required this.text,
      required this.ctrlAltDel,
      required this.lockScreen,
      required this.toast});

  factory RelaySink.session(SessionID sid) => RelaySink(
        key: (u, l, d) => bind.sessionHandleFlutterKeyEvent(
            sessionId: sid, character: '', usbHid: u, lockModes: l, downOrUp: d),
        mouse: (m) => bind.sessionSendMouse(sessionId: sid, msg: jsonEncode(m)),
        text: (v) => bind.sessionInputString(sessionId: sid, value: v),
        ctrlAltDel: () => bind.sessionCtrlAltDel(sessionId: sid),
        lockScreen: () => bind.sessionLockScreen(sessionId: sid),
        toast: (msg, d) => showToast(msg, timeout: d),
      );
}

class PhoneKbRelayServer {
  final String peerId;
  final RelaySink sink;
  final String? pinOverride;
  final int port;
  ServerSocket? _server;
  final _clients = <_RelayConn>{};
  late final String _pin;
  late final String _id;
  String _name = 'Tablet';
  int _badTries = 0;
  DateTime _badSince = DateTime.now();

  PhoneKbRelayServer(
      {required SessionID sessionId, required this.peerId})
      : sink = RelaySink.session(sessionId),
        pinOverride = null,
        port = kPhoneKbRelayPort;

  /// For tests: no RustDesk session, fixed PIN.
  PhoneKbRelayServer.test(
      {required this.peerId,
      required this.sink,
      required String pin,
      required this.port})
      : pinOverride = pin;

  static String pinOfThisDevice() {
    var pin = bind.mainGetLocalOption(key: _kPinOpt);
    if (pin.length != 6) {
      pin = _randomDigits(6);
      bind.mainSetLocalOption(key: _kPinOpt, value: pin);
    }
    return pin;
  }

  Future<void> start() async {
    if (pinOverride != null) {
      _pin = pinOverride!;
      _id = 'test';
    } else {
      _pin = pinOfThisDevice();
      _id = bind.mainGetLocalOption(key: _kIdOpt);
      if (_id.isEmpty) {
        _id = _randomDigits(12);
        bind.mainSetLocalOption(key: _kIdOpt, value: _id);
      }
      try {
        _name = (await DeviceInfoPluginHolder.model()) ?? _name;
      } catch (_) {}
    }
    try {
      _server = await ServerSocket.bind(InternetAddress.anyIPv4, port,
          shared: true);
      _server!.listen(_onClient, onError: (_) {});
    } catch (e) {
      debugPrint('phonekb relay: bind failed: $e');
    }
  }

  Future<void> stop() async {
    for (final c in _clients.toList()) {
      c.close();
    }
    _clients.clear();
    await _server?.close();
    _server = null;
  }

  void _onClient(Socket s) {
    s.setOption(SocketOption.tcpNoDelay, true);
    final c = _RelayConn(s);
    _clients.add(c);
    c.send({'t': 'hello', 'name': _name, 'peer': peerId, 'id': _id});
    // Unpaired connections (e.g. the phone scanning the network) are dropped soon.
    final authTimer = Timer(const Duration(seconds: 15), () {
      if (!c.authed) c.close();
    });
    c.lines.listen((line) {
      Map<String, dynamic> m;
      try {
        m = jsonDecode(line) as Map<String, dynamic>;
      } catch (_) {
        return;
      }
      _handle(c, m);
    }, onDone: () {
      authTimer.cancel();
      _release(c);
      _clients.remove(c);
      if (c.authed) sink.toast('手机键盘已断开', const Duration(seconds: 3));
    }, onError: (_) {});
  }

  void _handle(_RelayConn c, Map<String, dynamic> m) {
    final t = m['t'];
    if (t == 'p') {
      c.send({'t': 'p'});
      return;
    }
    if (!c.authed) {
      if (t != 'auth') return;
      final now = DateTime.now();
      if (now.difference(_badSince) > const Duration(minutes: 1)) {
        _badSince = now;
        _badTries = 0;
      }
      if (_badTries < 5 && m['pin'] == _pin) {
        c.authed = true;
        c.send({'t': 'ok'});
        sink.toast('手机键盘已连接', const Duration(seconds: 3));
      } else {
        _badTries++;
        c.send({'t': 'badpin'});
        // Show the PIN here so the person holding both devices can type it.
        sink.toast('手机键盘请求连接，配对码：$_pin', const Duration(seconds: 12));
      }
      return;
    }
    switch (t) {
      case 'k':
        final u = (m['u'] as num).toInt();
        final d = m['d'] == true;
        if (d) {
          c.downKeys.add(u);
        } else {
          c.downKeys.remove(u);
        }
        sink.key(u, (m['l'] as num?)?.toInt() ?? 0, d);
        break;
      case 'm':
        final mm = Map<String, dynamic>.from(m['m'] as Map);
        final b = mm['buttons'];
        if (b is String) {
          if (mm['type'] == 'down') c.downButtons.add(b);
          if (mm['type'] == 'up') c.downButtons.remove(b);
        }
        sink.mouse(mm);
        break;
      case 's':
        sink.text('${m['v']}');
        break;
      case 'cad':
        sink.ctrlAltDel();
        break;
      case 'lock':
        sink.lockScreen();
        break;
    }
  }

  // The phone dropped off: do not leave keys or buttons stuck down on the PC.
  void _release(_RelayConn c) {
    for (final u in c.downKeys) {
      sink.key(u, 0, false);
    }
    c.downKeys.clear();
    for (final b in c.downButtons) {
      sink.mouse({'type': 'up', 'buttons': b});
    }
    c.downButtons.clear();
  }
}

class _RelayConn {
  final Socket s;
  bool authed = false;
  final downKeys = <int>{};
  final downButtons = <String>{};
  late final Stream<String> lines;
  _RelayConn(this.s) {
    lines = utf8.decoder
        .bind(s)
        .transform(const LineSplitter())
        .asBroadcastStream();
  }
  void send(Map<String, dynamic> m) {
    try {
      s.add(utf8.encode('${jsonEncode(m)}\n'));
    } catch (_) {}
  }

  void close() {
    try {
      s.destroy();
    } catch (_) {}
  }
}

/// Device model name, e.g. "Xiaomi Pad 7S Pro".
class DeviceInfoPluginHolder {
  static Future<String?> model() async {
    final p = await Process.run('getprop', ['ro.product.marketname']);
    var name = '${p.stdout}'.trim();
    if (name.isEmpty) {
      final q = await Process.run('getprop', ['ro.product.model']);
      name = '${q.stdout}'.trim();
    }
    return name.isEmpty ? null : name;
  }
}

// ===========================================================================
// Phone side
// ===========================================================================

class FoundTablet {
  final String host;
  final String name;
  final String peer;
  final String id;
  FoundTablet(this.host, this.name, this.peer, this.id);
}

/// Look for tablets on every local /24 (hotspot or Wi-Fi), skipping VPN links.
Future<List<FoundTablet>> scanForTablets() async {
  final hosts = <String>{};
  try {
    final ifs = await NetworkInterface.list(type: InternetAddressType.IPv4);
    for (final i in ifs) {
      if (i.name.startsWith('tun') || i.name.startsWith('lo')) continue;
      for (final a in i.addresses) {
        final p = a.address.split('.');
        if (p.length != 4 || p[0] == '100' || p[0] == '127') continue;
        final base = '${p[0]}.${p[1]}.${p[2]}';
        for (var n = 1; n < 255; n++) {
          final h = '$base.$n';
          if (h != a.address) hosts.add(h);
        }
      }
    }
  } catch (_) {}
  final found = <FoundTablet>[];
  await Future.wait(hosts.map((h) async {
    final t = await probeTablet(h, timeout: const Duration(milliseconds: 700));
    if (t != null) found.add(t);
  }));
  found.sort((a, b) => a.host.compareTo(b.host));
  return found;
}

Future<FoundTablet?> probeTablet(String host,
    {Duration timeout = const Duration(seconds: 2)}) async {
  Socket? s;
  try {
    s = await Socket.connect(host, kPhoneKbRelayPort, timeout: timeout);
    final line = await utf8.decoder
        .bind(s)
        .transform(const LineSplitter())
        .first
        .timeout(const Duration(seconds: 2));
    final m = jsonDecode(line) as Map<String, dynamic>;
    if (m['t'] != 'hello') return null;
    return FoundTablet(host, '${m['name']}', '${m['peer']}', '${m['id']}');
  } catch (_) {
    return null;
  } finally {
    s?.destroy();
  }
}

enum RelayState { connecting, needPin, connected, lost }

class PhoneKbRelayClient {
  final String host;
  final int port;
  final String Function(String key) loadOpt;
  final void Function(String key, String value) saveOpt;
  final ValueNotifier<RelayState> state = ValueNotifier(RelayState.connecting);
  String tabletName = '';
  String tabletPeer = '';
  String _tabletId = '';
  Socket? _s;
  Timer? _ping;
  Timer? _retry;
  bool _closed = false;
  bool _pinRejected = false;

  PhoneKbRelayClient(this.host,
      {this.port = kPhoneKbRelayPort,
      String Function(String key)? loadOpt,
      void Function(String key, String value)? saveOpt})
      : loadOpt = loadOpt ?? ((k) => bind.mainGetLocalOption(key: k)),
        saveOpt =
            saveOpt ?? ((k, v) => bind.mainSetLocalOption(key: k, value: v));

  String get _pinKey => 'phonekb-relay-pin-of-$_tabletId';
  bool get pinRejected => _pinRejected;

  Future<void> connect() async {
    if (_closed) return;
    state.value = RelayState.connecting;
    try {
      final s = await Socket.connect(host, port,
          timeout: const Duration(seconds: 4));
      s.setOption(SocketOption.tcpNoDelay, true);
      _s = s;
      utf8.decoder.bind(s).transform(const LineSplitter()).listen(_onLine,
          onDone: _onDrop, onError: (_) => _onDrop());
    } catch (_) {
      _onDrop();
    }
  }

  void _onLine(String line) {
    Map<String, dynamic> m;
    try {
      m = jsonDecode(line) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    switch (m['t']) {
      case 'hello':
        tabletName = '${m['name']}';
        tabletPeer = '${m['peer']}';
        _tabletId = '${m['id']}';
        final pin = loadOpt(_pinKey);
        _send({'t': 'auth', 'pin': pin});
        break;
      case 'ok':
        _pinRejected = false;
        state.value = RelayState.connected;
        _ping?.cancel();
        _ping = Timer.periodic(
            const Duration(seconds: 5), (_) => _send({'t': 'p'}));
        break;
      case 'badpin':
        _pinRejected = loadOpt(_pinKey).isNotEmpty;
        state.value = RelayState.needPin;
        break;
    }
  }

  void _onDrop() {
    _ping?.cancel();
    _s?.destroy();
    _s = null;
    if (_closed) return;
    if (state.value != RelayState.needPin) state.value = RelayState.lost;
    _retry?.cancel();
    _retry = Timer(const Duration(seconds: 2), connect);
  }

  /// Save the PIN typed by the user and try again.
  void submitPin(String pin) {
    saveOpt(_pinKey, pin.trim());
    if (_s != null) {
      _send({'t': 'auth', 'pin': pin.trim()});
    } else {
      connect();
    }
  }

  void _send(Map<String, dynamic> m) {
    try {
      _s?.add(utf8.encode('${jsonEncode(m)}\n'));
    } catch (_) {}
  }

  void key(int usb, int lockModes, bool down) =>
      _send({'t': 'k', 'u': usb, 'l': lockModes, 'd': down});
  void mouse(Map<String, String> m) => _send({'t': 'm', 'm': m});
  void text(String v) => _send({'t': 's', 'v': v});
  void ctrlAltDel() => _send({'t': 'cad'});
  void lockScreen() => _send({'t': 'lock'});

  void close() {
    _closed = true;
    _ping?.cancel();
    _retry?.cancel();
    _s?.destroy();
    _s = null;
    state.dispose();
  }
}
