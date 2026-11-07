// PhoneKB: "模拟键盘" — use the phone as a keyboard and a tilt mouse for a remote PC.
//
// The session is keyboard-only (see `LoginConfigHandler::keyboard_only` in Rust): it sends real
// key down/up events (USB HID codes, map mode) and mouse events, drops video/audio without
// decoding, and never sends fps / quality / resolution / privacy options. So another device
// (e.g. a tablet) can keep viewing and controlling the same PC at the same time.
//
// Layout: portrait = mouse on top, keyboard in a drawer at the bottom.
//         landscape = keyboard split into two halves at the sides, mouse in the middle.

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:sensors_plus/sensors_plus.dart';

import '../../common.dart';
import '../../common/formatter/id_formatter.dart';
import '../../models/model.dart';
import '../../models/peer_model.dart';
import '../../models/platform_model.dart';
import 'home_page.dart';

const _kLastKeyboardPeer = 'phonekb-last-peer';

// ============================================================================
// Tab: choose the device
// ============================================================================

class KeyboardHomePage extends StatefulWidget implements PageShape {
  KeyboardHomePage({Key? key}) : super(key: key);

  @override
  final icon = const Icon(Icons.keyboard_alt_outlined);

  @override
  final title = '模拟键盘';

  @override
  final List<Widget> appBarActions = const [];

  @override
  State<KeyboardHomePage> createState() => _KeyboardHomePageState();
}

class _KeyboardHomePageState extends State<KeyboardHomePage> {
  final _idCtl = TextEditingController();
  List<Peer> _peers = [];
  Set<String> _favs = {};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _idCtl.text = bind.mainGetLocalOption(key: _kLastKeyboardPeer);
    _load();
  }

  @override
  void dispose() {
    _idCtl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final peers = <Peer>[];
    try {
      final s = await bind.mainLoadRecentPeersForAb(filter: '');
      if (s.isNotEmpty) {
        for (final m in jsonDecode(s) as List<dynamic>) {
          peers.add(Peer.fromJson(Map<String, dynamic>.from(m as Map)));
        }
      }
      _favs = (await bind.mainGetFav()).toSet();
    } catch (e) {
      debugPrint('phonekb: load peers failed: $e');
    }
    final favs = peers.where((p) => _favs.contains(p.id)).toList();
    final rest = peers.where((p) => !_favs.contains(p.id)).toList();
    if (!mounted) return;
    setState(() {
      _peers = [...favs, ...rest];
      _loading = false;
    });
  }

  void _open(String id) {
    id = id.replaceAll(' ', '');
    if (id.isEmpty) return;
    bind.mainSetLocalOption(key: _kLastKeyboardPeer, value: id);
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => KeyboardSessionPage(id: id)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('把手机当成电脑的键盘和鼠标',
              style: theme.textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.bold)),
          const SizedBox(height: 6),
          Text(
            '只发送按键和鼠标，不接收画面和声音，不改电脑的分辨率和画质。'
            '平板等其他设备可以同时用 RustDesk 显示和控制这台电脑，互不影响。',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 16),
          Row(children: [
            Expanded(
              child: TextField(
                controller: _idCtl,
                keyboardType: TextInputType.visiblePassword,
                decoration: const InputDecoration(
                  labelText: '电脑的 ID 或 IP',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                onSubmitted: _open,
              ),
            ),
            const SizedBox(width: 10),
            FilledButton.icon(
              onPressed: () => _open(_idCtl.text),
              icon: const Icon(Icons.keyboard),
              label: const Text('连接'),
            ),
          ]),
          const SizedBox(height: 20),
          Text('最近连接 / 收藏', style: theme.textTheme.labelLarge),
          const SizedBox(height: 6),
          if (_loading)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (_peers.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Text('还没有连接过的设备，在上面输入电脑的 ID 或 IP。',
                  style: theme.textTheme.bodySmall),
            )
          else
            ..._peers.map((p) {
              final name = p.alias.isNotEmpty
                  ? p.alias
                  : (p.hostname.isNotEmpty ? p.hostname : p.id);
              final sub = [
                formatID(p.id),
                if (p.platform.isNotEmpty) p.platform,
                if (p.username.isNotEmpty) p.username,
              ].join(' · ');
              return Card(
                child: ListTile(
                  leading: Icon(_favs.contains(p.id)
                      ? Icons.star_rounded
                      : Icons.computer_outlined),
                  title: Text(name),
                  subtitle: Text(sub),
                  trailing: const Icon(Icons.keyboard_arrow_right),
                  onTap: () => _open(p.id),
                ),
              );
            }),
        ],
      ),
    );
  }
}

// ============================================================================
// Keys
// ============================================================================

class _K {
  final String label;
  final String sub; // shifted symbol shown small
  final int code; // USB HID usage (page 7)
  final bool isMod;
  final bool shift; // symbol layer: send with Shift
  final int flex; // width in quarter keys
  const _K(this.label, this.code,
      {this.sub = '', this.flex = 4, this.shift = false})
      : isMod = false;
  const _K.mod(this.label, this.code, {this.flex = 4})
      : sub = '',
        isMod = true,
        shift = false;
}

// HID usages
const _ctrl = 0xE0, _shift = 0xE1, _alt = 0xE2, _win = 0xE3;
const _esc = 0x29, _tab = 0x2B, _capsKey = 0x39, _enter = 0x28, _bksp = 0x2A;
const _space = 0x2C, _del = 0x4C, _f4 = 0x3D;
const _home = 0x4A, _end = 0x4D, _pgUp = 0x4B, _pgDn = 0x4E;
const _up = 0x52, _down = 0x51, _left = 0x50, _right = 0x4F;
int _letter(String c) => 0x04 + c.toLowerCase().codeUnitAt(0) - 0x61;
List<_K> _letters(String s) => [for (final c in s.split('')) _K(c, _letter(c))];
const _digitSubs = '!@#\$%^&*()';
_K _digit(int i) => _K(i == 9 ? '0' : '${i + 1}', i == 9 ? 0x27 : 0x1E + i,
    sub: _digitSubs[i]);

// Landscape: split keyboard, left hand half and right hand half.
final List<List<_K>> _leftHalf = [
  [
    const _K('Esc', _esc),
    for (var i = 1; i <= 6; i++) _K('F$i', 0x3A + i - 1),
  ],
  [const _K('`', 0x35, sub: '~'), for (var i = 0; i < 6; i++) _digit(i)],
  [const _K('Tab', _tab, flex: 6), ..._letters('QWERT')],
  [const _K('Caps', _capsKey, flex: 7), ..._letters('ASDFG')],
  [const _K.mod('Shift', _shift, flex: 9), ..._letters('ZXCVB')],
  [
    const _K.mod('Ctrl', _ctrl),
    const _K.mod('Win', _win),
    const _K.mod('Alt', _alt),
    const _K('space', _space, flex: 10),
  ],
];

final List<List<_K>> _rightHalf = [
  [
    for (var i = 7; i <= 12; i++) _K('F$i', 0x3A + i - 1),
    const _K('Del', _del),
  ],
  [
    for (var i = 6; i < 10; i++) _digit(i),
    const _K('-', 0x2D, sub: '_'),
    const _K('=', 0x2E, sub: '+'),
    const _K('⌫', _bksp, flex: 6),
  ],
  [
    ..._letters('YUIOP'),
    const _K('[', 0x2F, sub: '{'),
    const _K(']', 0x30, sub: '}'),
    const _K('\\', 0x31, sub: '|'),
  ],
  [
    ..._letters('HJKL'),
    const _K(';', 0x33, sub: ':'),
    const _K("'", 0x34, sub: '"'),
    const _K('Enter', _enter, flex: 7),
  ],
  [
    ..._letters('NM'),
    const _K(',', 0x36, sub: '<'),
    const _K('.', 0x37, sub: '>'),
    const _K('/', 0x38, sub: '?'),
    const _K('↑', _up),
    const _K.mod('Shift', _shift, flex: 5),
  ],
  [
    const _K('space', _space, flex: 9),
    const _K.mod('Alt', _alt),
    const _K.mod('Ctrl', _ctrl),
    const _K('←', _left),
    const _K('↓', _down),
    const _K('→', _right),
  ],
];

// Portrait: phone-style keyboard, with a symbol layer.
final List<_K> _pTop = [
  const _K('Esc', _esc),
  const _K('Tab', _tab),
  const _K('Home', _home),
  const _K('End', _end),
  const _K('PgUp', _pgUp),
  const _K('PgDn', _pgDn),
  const _K('Del', _del),
];
final List<_K> _pDigits = [for (var i = 0; i < 10; i++) _digit(i)];
final List<List<_K>> _pLetters = [
  _letters('QWERTYUIOP'),
  _letters('ASDFGHJKL'),
  [
    const _K.mod('Shift', _shift, flex: 6),
    ..._letters('ZXCVBNM'),
    const _K(',', 0x36, sub: '<'),
    const _K('.', 0x37, sub: '>'),
    const _K('⌫', _bksp, flex: 6),
  ],
];
final List<List<_K>> _pSymbols = [
  [
    for (var i = 0; i < 10; i++)
      _K(_digitSubs[i], i == 9 ? 0x27 : 0x1E + i, shift: true),
  ],
  const [
    _K('`', 0x35),
    _K('-', 0x2D),
    _K('=', 0x2E),
    _K('[', 0x2F),
    _K(']', 0x30),
    _K('\\', 0x31),
    _K(';', 0x33),
    _K("'", 0x34),
    _K('/', 0x38),
    _K('?', 0x38, shift: true),
  ],
  const [
    _K.mod('Shift', _shift, flex: 6),
    _K('~', 0x35, shift: true),
    _K('_', 0x2D, shift: true),
    _K('+', 0x2E, shift: true),
    _K('{', 0x2F, shift: true),
    _K('}', 0x30, shift: true),
    _K('|', 0x31, shift: true),
    _K(':', 0x33, shift: true),
    _K('"', 0x34, shift: true),
    _K('⌫', _bksp, flex: 6),
  ],
];
final List<_K> _pArrows = [
  const _K('←', _left),
  const _K('↑', _up),
  const _K('↓', _down),
  const _K('→', _right),
];

// ============================================================================
// Session page
// ============================================================================

class KeyboardSessionPage extends StatefulWidget {
  final String id;
  const KeyboardSessionPage({Key? key, required this.id}) : super(key: key);

  @override
  State<KeyboardSessionPage> createState() => _KeyboardSessionPageState();
}

class _KeyboardSessionPageState extends State<KeyboardSessionPage>
    with WidgetsBindingObserver {
  final _uniqueKey = UniqueKey();
  final _textCtl = TextEditingController();

  SessionID get _sid => gFFI.sessionId;

  // ---- UI state ----
  bool _showText = false;
  bool _drawerOpen = false; // portrait keyboard drawer
  bool _leftOpen = true, _rightOpen = true; // landscape halves
  bool _symLayer = false; // portrait symbol layer
  bool _landscape = false;

  // ---- key state ----
  final Map<int, int> _heldCount = {}; // modifier -> fingers on it
  final Set<int> _chordUsed = {}; // held modifiers already combined with a key
  final Set<int> _latched = {}; // tapped once: applies to the next key
  final Set<int> _locked = {}; // tapped twice: applies until tapped again
  final Set<int> _sentMods = {}; // modifiers currently down on the PC
  final Set<int> _downKeys = {}; // normal keys currently down on the PC
  final Set<_K> _pressedUi = {}; // keys drawn as pressed
  bool _capsOn = false;
  Timer? _repeatTimer;
  int _repeatCode = 0;

  // ---- tilt mouse state ----
  StreamSubscription<AccelerometerEvent>? _accSub;
  double _ax = 0, _ay = 0;
  bool _accReady = false;
  bool _moving = false; // clutch held or locked on
  bool _moveLocked = false; // double-tapped: stays on
  int _lastClutchDown = 0;
  bool _landSignPos = true; // landscape: device +x points up
  double _baseR = 0, _baseU = 0;
  double _remX = 0, _remY = 0;
  Timer? _tick;
  int _lastTickUs = 0;
  int _sens = 1; // 0 low, 1 mid, 2 high
  final _tilt = ValueNotifier<Offset>(Offset.zero); // -1..1, for the indicator
  double _wheelAcc = 0;

  Set<int> get _held =>
      _heldCount.entries.where((e) => e.value > 0).map((e) => e.key).toSet();

  @override
  void initState() {
    super.initState();
    SystemChrome.setPreferredOrientations([]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    gFFI.ffiModel.updateEventListener(_sid, widget.id);
    gFFI.start(widget.id, keyboardOnly: true);
    WakelockManager.enable(_uniqueKey);
    WidgetsBinding.instance.addObserver(this);
    _accSub = accelerometerEventStream(
            samplingPeriod: SensorInterval.gameInterval)
        .listen((e) {
      // Low-pass filter: the accelerometer is noisy, we only want the tilt.
      if (!_accReady) {
        _ax = e.x;
        _ay = e.y;
        _accReady = true;
      } else {
        _ax += (e.x - _ax) * 0.25;
        _ay += (e.y - _ay) * 0.25;
      }
    }, onError: (_) {});
    _lastTickUs = DateTime.now().microsecondsSinceEpoch;
    _tick = Timer.periodic(const Duration(milliseconds: 16), (_) => _onTick());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      _releaseAll();
      _stopMove();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _tick?.cancel();
    _accSub?.cancel();
    _releaseAll();
    unawaited(bind.sessionClose(sessionId: _sid));
    super.dispose();
    () async {
      await gFFI.close();
      gFFI.dialogManager.dismissAll();
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.manual,
          overlays: SystemUiOverlay.values);
      WakelockManager.disable(_uniqueKey);
    }();
    _textCtl.dispose();
    _tilt.dispose();
  }

  // ==========================================================================
  // Keyboard sending
  // ==========================================================================

  void _send(int usb, bool down) {
    bind.sessionHandleFlutterKeyEvent(
      sessionId: _sid,
      character: '',
      usbHid: usb,
      lockModes: _capsOn ? (1 << 1) : 0, // CAPS_LOCK bit, see keyboard.rs
      downOrUp: down,
    );
  }

  void _modsDown(Set<int> mods) {
    for (final m in mods) {
      if (_sentMods.add(m)) _send(m, true);
    }
  }

  void _modsUpExcept(Set<int> keep) {
    for (final m in _sentMods.difference(keep).toList()) {
      _send(m, false);
      _sentMods.remove(m);
    }
  }

  void _keyDown(_K k) {
    final code = k.code;
    final held = _held;
    _chordUsed.addAll(held);
    _modsDown({...held, ..._latched, ..._locked, if (k.shift) _shift});
    if (code == _capsKey) _capsOn = !_capsOn;
    _send(code, true);
    _downKeys.add(code);
    // The PC does not auto-repeat injected keys, so repeat like a real keyboard does.
    _repeatTimer?.cancel();
    _repeatCode = code;
    if (code != _capsKey) {
      _repeatTimer = Timer(const Duration(milliseconds: 400), () {
        _repeatTimer = Timer.periodic(const Duration(milliseconds: 40), (_) {
          if (_downKeys.contains(_repeatCode)) _send(_repeatCode, true);
        });
      });
    }
  }

  void _keyUp(_K k) {
    final code = k.code;
    if (_repeatCode == code) {
      _repeatTimer?.cancel();
      _repeatTimer = null;
      _repeatCode = 0;
    }
    if (_downKeys.remove(code)) _send(code, false);
    if (_downKeys.isEmpty) {
      _latched.clear();
      _modsUpExcept(_held.intersection(_chordUsed));
    }
  }

  void _modDown(int m) {
    _heldCount[m] = (_heldCount[m] ?? 0) + 1;
    if (_downKeys.isNotEmpty) {
      _chordUsed.add(m);
      _modsDown({m});
    }
  }

  void _modUp(int m) {
    final n = (_heldCount[m] ?? 0) - 1;
    _heldCount[m] = n < 0 ? 0 : n;
    if (n > 0) return;
    if (_chordUsed.remove(m)) {
      if (_downKeys.isEmpty || !(_latched.contains(m) || _locked.contains(m))) {
        if (_sentMods.remove(m)) _send(m, false);
      }
    } else if (m == _win) {
      _send(_win, true); // tap Win alone: Start menu
      _send(_win, false);
    } else if (_locked.remove(m)) {
      // locked -> off
    } else if (_latched.remove(m)) {
      _locked.add(m); // once -> locked
    } else {
      _latched.add(m); // off -> once
    }
  }

  void _releaseAll() {
    _repeatTimer?.cancel();
    _repeatTimer = null;
    _repeatCode = 0;
    for (final k in _downKeys) {
      _send(k, false);
    }
    _downKeys.clear();
    for (final m in _sentMods) {
      _send(m, false);
    }
    _sentMods.clear();
    _heldCount.clear();
    _chordUsed.clear();
    _latched.clear();
    _pressedUi.clear();
  }

  Future<void> _combo(List<int> mods, int key) async {
    final fresh = mods.where((m) => !_sentMods.contains(m)).toList();
    for (final m in fresh) {
      _send(m, true);
    }
    _send(key, true);
    await Future.delayed(const Duration(milliseconds: 30));
    _send(key, false);
    for (final m in fresh.reversed) {
      _send(m, false);
    }
  }

  void _tapMod(int m) {
    _send(m, true);
    _send(m, false);
  }

  void _sendText({bool enter = false}) {
    final t = _textCtl.text;
    if (t.isNotEmpty) {
      bind.sessionInputString(sessionId: _sid, value: t);
      _textCtl.clear();
    }
    if (enter) {
      Future.delayed(const Duration(milliseconds: 80), () => _combo([], _enter));
    }
  }

  // ==========================================================================
  // Mouse sending
  // ==========================================================================

  void _mouse(Map<String, String> m) {
    bind.sessionSendMouse(sessionId: _sid, msg: json.encode(m));
  }

  void _button(String b, bool down) =>
      _mouse({'type': down ? 'down' : 'up', 'buttons': b});

  // Screen axes as seen by the accelerometer: R points to the screen's right,
  // U to the screen's top. A reading drops along an axis that tilts downwards.
  (double, double) _axes() {
    if (!_landscape) return (_ax, _ay);
    return _landSignPos ? (-_ay, _ax) : (_ay, -_ax);
  }

  void _startMove() {
    if (_landscape) _landSignPos = _ax >= 0;
    final (r, u) = _axes();
    _baseR = r;
    _baseU = u;
    _remX = 0;
    _remY = 0;
    _moving = true;
  }

  void _stopMove() {
    _moving = false;
    _moveLocked = false;
  }

  // m/s² of tilt -> -1..1, with a dead zone so a shaking hand does not move the cursor.
  static double _curve(double v) {
    const dead = 0.5, full = 5.0; // about 3° and 30°
    final a = v.abs();
    if (a <= dead) return 0;
    final t = ((a - dead) / (full - dead)).clamp(0.0, 1.0);
    return v.sign * math.pow(t, 1.6).toDouble();
  }

  void _onTick() {
    final now = DateTime.now().microsecondsSinceEpoch;
    final dt = (now - _lastTickUs) / 1e6;
    _lastTickUs = now;
    if (!_accReady) return;
    if (!_landscape || !_moving) _landSignPos = _ax >= 0 || !_landscape;
    final (r, u) = _axes();
    // Tilting right lowers the right edge, tilting forward lowers the top edge.
    final vx = _curve(-(r - _baseR));
    final vy = _curve(-(u - _baseU));
    _tilt.value = Offset(vx, vy);
    if (!_moving) return;
    final speed = const [700.0, 1400.0, 2400.0][_sens]; // px per second at full tilt
    _remX += vx * speed * dt;
    _remY += vy * speed * dt;
    final x = _remX.truncate(), y = _remY.truncate();
    _remX -= x;
    _remY -= y;
    if (x != 0 || y != 0) {
      _mouse({'type': 'move_relative', 'x': '$x', 'y': '$y'});
    }
  }

  void _clutchDown() {
    final now = DateTime.now().millisecondsSinceEpoch;
    final dbl = now - _lastClutchDown < 300;
    _lastClutchDown = now;
    setState(() {
      if (_moveLocked) {
        _stopMove(); // tap while locked: off
      } else if (dbl) {
        _startMove();
        _moveLocked = true; // double tap: stay on
      } else {
        _startMove();
      }
    });
  }

  void _clutchUp() {
    if (!_moveLocked) setState(_stopMove);
  }

  // ==========================================================================
  // UI
  // ==========================================================================

  static const _bg = Color(0xFF0F1012);
  static const _panel = Color(0xFF16171A);
  static const _btn = Color(0xFF1D1E22);
  static const _keyColor = Color(0xFF2A2C31);
  static const _modColor = Color(0xFF202125);
  static const _downColor = Color(0xFF0A84FF);
  static const _latchColor = Color(0xFF0A5FB8);
  static const _lockColor = Color(0xFFD9822B);
  static const _green = Color(0xFF30D158);
  static const _textColor = Color(0xFFF2F2F7);
  static const _subColor = Color(0xFF7C7E86);
  static const _dimColor = Color(0xFF6E7078);

  Color _colorOf(_K k) {
    if (k.isMod) {
      if (_held.contains(k.code)) return _downColor;
      if (_locked.contains(k.code)) return _lockColor;
      if (_latched.contains(k.code)) return _latchColor;
      return _modColor;
    }
    if (_pressedUi.contains(k)) return _downColor;
    if (k.code == _capsKey && _capsOn) return _lockColor;
    return _keyColor;
  }

  bool _isFnLike(_K k) =>
      k.isMod ||
      k.label.length > 1 && k.code != _space && !k.label.startsWith('F') ||
      const [_up, _down, _left, _right].contains(k.code);

  Widget _key(_K k) {
    void up() => setState(() {
          if (k.isMod) {
            _modUp(k.code);
          } else {
            _pressedUi.remove(k);
            _keyUp(k);
          }
        });
    return Expanded(
      flex: k.flex,
      child: Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: (_) {
          HapticFeedback.selectionClick();
          setState(() {
            if (k.isMod) {
              _modDown(k.code);
            } else {
              _pressedUi.add(k);
              _keyDown(k);
            }
          });
        },
        onPointerUp: (_) => up(),
        onPointerCancel: (_) => up(),
        child: LayoutBuilder(builder: (context, c) {
          final h = c.maxHeight;
          final fn = _isFnLike(k) && !k.isMod;
          final mainSize = (k.label.length > 2 || fn || k.isMod)
              ? (h * 0.27).clamp(9.0, 15.0)
              : (h * 0.40).clamp(10.0, 22.0);
          return Container(
            margin: const EdgeInsets.all(2),
            decoration: BoxDecoration(
              color: _colorOf(k),
              borderRadius: BorderRadius.circular(7),
              border: const Border(
                  bottom: BorderSide(color: Color(0xFF1C1D21), width: 2)),
            ),
            alignment: Alignment.center,
            child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
              if (k.sub.isNotEmpty)
                Text(k.sub,
                    style: TextStyle(
                        color: _subColor,
                        fontSize: (h * 0.22).clamp(8.0, 12.0),
                        height: 1.0)),
              Text(k.label,
                  maxLines: 1,
                  overflow: TextOverflow.clip,
                  style: TextStyle(
                    color: k.code == _space
                        ? const Color(0xFF5D5F66)
                        : (k.isMod ? const Color(0xFFC7C7CC) : _textColor),
                    fontSize: mainSize,
                    fontWeight: k.isMod ? FontWeight.w600 : FontWeight.w400,
                    height: 1.05,
                  )),
            ]),
          );
        }),
      ),
    );
  }

  Widget _row(List<_K> keys, {int flex = 10, double pad = 0}) => Expanded(
        flex: flex,
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: pad),
          child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: keys.map(_key).toList()),
        ),
      );

  Widget _iconBtn(IconData icon, VoidCallback onTap,
      {bool on = false, String? tip}) {
    return Padding(
      padding: const EdgeInsets.only(left: 6),
      child: Material(
        color: on ? const Color(0xFF16324F) : _btn,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: () {
            HapticFeedback.selectionClick();
            onTap();
          },
          child: SizedBox(
            width: 38,
            height: 34,
            child: Icon(icon,
                size: 19,
                color: on ? const Color(0xFF8CC4FF) : const Color(0xFFD1D1D6)),
          ),
        ),
      ),
    );
  }

  Widget _topBar() {
    final kbOpen = _leftOpen || _rightOpen;
    return SizedBox(
      height: 44,
      child: Row(children: [
        _iconBtn(Icons.close, () => Navigator.pop(context)),
        const SizedBox(width: 8),
        Obx(() {
          final ok = gFFI.ffiModel.pi.isSet.value;
          final kbOff = gFFI.ffiModel.permissions['keyboard'] == false;
          final color = !ok ? const Color(0xFFFF9F0A) : (kbOff ? const Color(0xFFFF453A) : _green);
          final text = !ok
              ? '正在连接…'
              : (kbOff ? '电脑端关闭了键鼠权限' : formatID(widget.id));
          return Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            decoration: BoxDecoration(
                color: _btn, borderRadius: BorderRadius.circular(16)),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Container(
                  width: 8,
                  height: 8,
                  decoration:
                      BoxDecoration(color: color, shape: BoxShape.circle)),
              const SizedBox(width: 7),
              Text(text,
                  style:
                      const TextStyle(color: Color(0xFFD1D1D6), fontSize: 13)),
            ]),
          );
        }),
        const Spacer(),
        if (_landscape)
          _iconBtn(Icons.keyboard_outlined, () {
            setState(() {
              _leftOpen = !kbOpen;
              _rightOpen = !kbOpen;
            });
          }, on: kbOpen),
        _iconBtn(Icons.handyman_outlined, _openToolbox),
        _iconBtn(Icons.chat_bubble_outline,
            () => setState(() => _showText = !_showText),
            on: _showText),
        const SizedBox(width: 6),
      ]),
    );
  }

  Widget _textRow() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 6),
      child: Row(children: [
        Expanded(
          child: TextField(
            controller: _textCtl,
            style: const TextStyle(color: _textColor, fontSize: 14),
            decoration: InputDecoration(
              hintText: '在这里打字（中文也行），一次性发到电脑',
              hintStyle: const TextStyle(color: _dimColor),
              filled: true,
              fillColor: _keyColor,
              isDense: true,
              border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide.none),
            ),
            onSubmitted: (_) => _sendText(),
          ),
        ),
        _iconBtn(Icons.send, _sendText),
        _iconBtn(Icons.keyboard_return, () => _sendText(enter: true)),
      ]),
    );
  }

  // ---- mouse panel ----

  Widget _tiltPad() {
    return Container(
      decoration: BoxDecoration(
          color: _panel, borderRadius: BorderRadius.circular(16)),
      child: LayoutBuilder(builder: (context, c) {
        final r = math.min(c.maxWidth, c.maxHeight) * 0.4;
        return Stack(alignment: Alignment.center, children: [
          Container(
            width: r * 2,
            height: r * 2,
            decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: const Color(0xFF23252A))),
          ),
          Container(
            width: r * 0.55,
            height: r * 0.55,
            decoration: const BoxDecoration(
                shape: BoxShape.circle, color: Color(0xFF1D1F24)),
          ),
          Container(width: 1, height: r * 2, color: const Color(0xFF202226)),
          Container(height: 1, width: r * 2, color: const Color(0xFF202226)),
          ValueListenableBuilder<Offset>(
            valueListenable: _tilt,
            builder: (context, t, _) => Transform.translate(
              offset: Offset(t.dx * r, t.dy * r),
              child: Container(
                width: 22,
                height: 22,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: _moving ? _green : _downColor,
                  border: Border.all(color: _bg, width: 4),
                ),
              ),
            ),
          ),
          const Positioned(
              top: 9,
              left: 12,
              child: Text('倾斜', style: TextStyle(color: _dimColor, fontSize: 12))),
          Positioned(
            top: 7,
            right: 9,
            child: GestureDetector(
              onTap: () => setState(() => _sens = (_sens + 1) % 3),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                    color: const Color(0xFF1F2125),
                    borderRadius: BorderRadius.circular(10)),
                child: Text('灵敏度 ${const ['低', '中', '高'][_sens]}',
                    style: const TextStyle(
                        color: Color(0xFF9A9CA4), fontSize: 12)),
              ),
            ),
          ),
        ]);
      }),
    );
  }

  Widget _clutch(double h) {
    final on = _moving;
    return Listener(
      onPointerDown: (_) {
        HapticFeedback.lightImpact();
        _clutchDown();
      },
      onPointerUp: (_) => _clutchUp(),
      onPointerCancel: (_) => _clutchUp(),
      child: Container(
        height: h,
        decoration: BoxDecoration(
            color: on ? _green : _downColor,
            borderRadius: BorderRadius.circular(16)),
        alignment: Alignment.center,
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.open_with,
              size: 22, color: on ? const Color(0xFF0B2A12) : Colors.white),
          const SizedBox(width: 10),
          Text(
            _moveLocked ? '常开中（点一下关闭）' : (on ? '移动中' : '按住移动 · 双击常开'),
            style: TextStyle(
                color: on ? const Color(0xFF0B2A12) : Colors.white,
                fontSize: 15,
                fontWeight: FontWeight.w600),
          ),
        ]),
      ),
    );
  }

  Widget _mouseButton(String label, String button, {bool mirror = false}) {
    return Expanded(
      child: _PressBox(
        onDown: () {
          HapticFeedback.selectionClick();
          _button(button, true);
        },
        onUp: () => _button(button, false),
        builder: (pressed) => Container(
          decoration: BoxDecoration(
              color: pressed ? _downColor : const Color(0xFF24262B),
              borderRadius: BorderRadius.circular(14)),
          alignment: Alignment.center,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Transform.flip(
                flipX: mirror,
                child: const Icon(Icons.mouse_outlined,
                    size: 18, color: Color(0xFF8E8E93))),
            const SizedBox(height: 2),
            Text(label,
                style: const TextStyle(color: Color(0xFFE5E5EA), fontSize: 14)),
          ]),
        ),
      ),
    );
  }

  Widget _wheel() {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        HapticFeedback.selectionClick();
        _button('wheel', true); // tap: middle click
        _button('wheel', false);
      },
      onVerticalDragStart: (_) => _wheelAcc = 0,
      onVerticalDragUpdate: (d) {
        _wheelAcc += d.delta.dy;
        const step = 18.0;
        while (_wheelAcc.abs() >= step) {
          // Finger up = scroll up, like pushing a wheel forward.
          final dir = _wheelAcc < 0 ? 1 : -1;
          _mouse({'type': 'wheel', 'y': '$dir'});
          HapticFeedback.selectionClick();
          _wheelAcc += dir * step;
        }
      },
      child: Container(
        width: 52,
        decoration: BoxDecoration(
            color: _panel, borderRadius: BorderRadius.circular(14)),
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Column(children: [
          const Icon(Icons.keyboard_arrow_up, color: _dimColor, size: 18),
          Expanded(
            child: Container(
              width: 18,
              margin: const EdgeInsets.symmetric(vertical: 2),
              decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(9),
                  color: const Color(0xFF1F2125)),
              child: LayoutBuilder(
                builder: (context, c) => Column(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: List.generate(
                      math.max(1, (c.maxHeight / 7).floor()),
                      (_) => Container(
                          height: 2, width: 12, color: const Color(0xFF34363C))),
                ),
              ),
            ),
          ),
          const Icon(Icons.keyboard_arrow_down, color: _dimColor, size: 18),
        ]),
      ),
    );
  }

  Widget _mousePanel({required double clutchH, required double buttonsH}) {
    return Column(children: [
      Expanded(child: _tiltPad()),
      const SizedBox(height: 8),
      _clutch(clutchH),
      const SizedBox(height: 8),
      SizedBox(
        height: buttonsH,
        child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          _mouseButton('左键', 'left'),
          const SizedBox(width: 7),
          _wheel(),
          const SizedBox(width: 7),
          _mouseButton('右键', 'right', mirror: true),
        ]),
      ),
    ]);
  }

  // ---- toolbox ----

  void _openToolbox() {
    final groups = <(String, List<(String, VoidCallback)>)>[
      (
        '常用',
        [
          ('中/英', () => _tapMod(_shift)),
          ('切输入法', () => _combo([_win], _space)),
          ('复制', () => _combo([_ctrl], _letter('c'))),
          ('粘贴', () => _combo([_ctrl], _letter('v'))),
          ('剪切', () => _combo([_ctrl], _letter('x'))),
          ('撤销', () => _combo([_ctrl], _letter('z'))),
          ('全选', () => _combo([_ctrl], _letter('a'))),
          ('保存', () => _combo([_ctrl], _letter('s'))),
        ]
      ),
      (
        '系统',
        [
          ('Ctrl+Alt+Del', () => bind.sessionCtrlAltDel(sessionId: _sid)),
          ('任务管理器', () => _combo([_ctrl, _shift], _esc)),
          ('Alt+Tab', () => _combo([_alt], _tab)),
          ('回桌面', () => _combo([_win], _letter('d'))),
          ('截图', () => _combo([_win, _shift], _letter('s'))),
          ('关窗口', () => _combo([_alt], _f4)),
          ('资源管理器', () => _combo([_win], _letter('e'))),
          ('锁屏', () => bind.sessionLockScreen(sessionId: _sid)),
        ]
      ),
      (
        'F 键',
        [
          for (var i = 1; i <= 12; i++) ('F$i', () => _combo([], 0x3A + i - 1)),
        ]
      ),
      (
        '导航',
        [
          ('Home', () => _combo([], _home)),
          ('End', () => _combo([], _end)),
          ('PgUp', () => _combo([], _pgUp)),
          ('PgDn', () => _combo([], _pgDn)),
          ('Insert', () => _combo([], 0x49)),
          ('PrtSc', () => _combo([], 0x46)),
          ('Caps', () => _combo([], _capsKey)),
          ('Esc', () => _combo([], _esc)),
        ]
      ),
    ];
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1B1C20),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(18))),
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                    width: 40,
                    height: 4,
                    margin: const EdgeInsets.only(bottom: 8),
                    decoration: BoxDecoration(
                        color: const Color(0xFF3A3C42),
                        borderRadius: BorderRadius.circular(2))),
              ),
              for (final g in groups) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(2, 8, 2, 6),
                  child: Text(g.$1,
                      style: const TextStyle(color: Color(0xFF8E8E93), fontSize: 12)),
                ),
                GridView.count(
                  crossAxisCount: _landscape ? 8 : 4,
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  mainAxisSpacing: 6,
                  crossAxisSpacing: 6,
                  childAspectRatio: 2.2,
                  children: [
                    for (final a in g.$2)
                      Material(
                        color: _keyColor,
                        borderRadius: BorderRadius.circular(9),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(9),
                          onTap: () {
                            HapticFeedback.selectionClick();
                            a.$2();
                          },
                          child: Center(
                            child: Text(a.$1,
                                style: const TextStyle(
                                    color: _textColor, fontSize: 12.5)),
                          ),
                        ),
                      ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  // ---- layouts ----

  Widget _portrait(Size size) {
    final kbH = size.height * 0.44;
    final rows = _symLayer ? _pSymbols : _pLetters;
    final modRow = <_K>[
      const _K.mod('Ctrl', _ctrl),
      const _K.mod('Win', _win),
      const _K.mod('Alt', _alt),
    ];
    return Column(children: [
      _topBar(),
      if (_showText) _textRow(),
      Expanded(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 2, 12, 10),
          child: _mousePanel(
              clutchH: _drawerOpen ? 54 : 70,
              buttonsH: _drawerOpen ? 62 : 100),
        ),
      ),
      AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
        height: _drawerOpen ? kbH + 40 : 40,
        decoration: const BoxDecoration(
            color: Color(0xFF141518),
            borderRadius: BorderRadius.vertical(top: Radius.circular(18))),
        child: ClipRect(
          child: OverflowBox(
            alignment: Alignment.topCenter,
            minHeight: kbH + 40,
            maxHeight: kbH + 40,
            child: Column(children: [
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => setState(() => _drawerOpen = !_drawerOpen),
                onVerticalDragEnd: (d) {
                  final v = d.primaryVelocity ?? 0;
                  if (v < -100) setState(() => _drawerOpen = true);
                  if (v > 100) setState(() => _drawerOpen = false);
                },
                child: SizedBox(
                  height: 40,
                  child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Container(
                            width: 42,
                            height: 5,
                            decoration: BoxDecoration(
                                color: const Color(0xFF3A3C42),
                                borderRadius: BorderRadius.circular(3))),
                        const SizedBox(height: 4),
                        Text(_drawerOpen ? '下滑收起键盘' : '上滑打开键盘',
                            style: const TextStyle(
                                color: _dimColor, fontSize: 12)),
                      ]),
                ),
              ),
              SizedBox(
                height: kbH,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(4, 0, 4, 6),
                  child: Column(children: [
                    _row(_pTop, flex: 8),
                    _row(_pDigits),
                    _row(rows[0]),
                    _row(rows[1], pad: _symLayer ? 0 : size.width * 0.04),
                    _row(rows[2]),
                    Expanded(
                      flex: 10,
                      child: Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            ...modRow.map(_key),
                            Expanded(
                              flex: 4,
                              child: GestureDetector(
                                behavior: HitTestBehavior.opaque,
                                onTap: () =>
                                    setState(() => _symLayer = !_symLayer),
                                child: Container(
                                  margin: const EdgeInsets.all(2),
                                  decoration: BoxDecoration(
                                      color: _symLayer ? _latchColor : _modColor,
                                      borderRadius: BorderRadius.circular(7)),
                                  alignment: Alignment.center,
                                  child: Text(_symLayer ? 'ABC' : '符',
                                      style: const TextStyle(
                                          color: Color(0xFFC7C7CC),
                                          fontSize: 13,
                                          fontWeight: FontWeight.w600)),
                                ),
                              ),
                            ),
                            _key(const _K('space', _space, flex: 12)),
                            _key(const _K('Enter', _enter, flex: 7)),
                          ]),
                    ),
                    _row(_pArrows, flex: 8, pad: size.width * 0.2),
                  ]),
                ),
              ),
            ]),
          ),
        ),
      ),
    ]);
  }

  Widget _half(List<List<_K>> rows, bool open, double w, bool left) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      width: open ? w : 0,
      child: ClipRect(
        child: OverflowBox(
          alignment: left ? Alignment.centerRight : Alignment.centerLeft,
          minWidth: w,
          maxWidth: w,
          child: Column(children: [
            for (var i = 0; i < rows.length; i++)
              _row(rows[i], flex: i == 0 ? 7 : 10),
          ]),
        ),
      ),
    );
  }

  Widget _sideTab(bool open, bool left, VoidCallback onTap) {
    final pointsLeft = left ? open : !open;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: SizedBox(
        width: 22,
        child: Icon(pointsLeft ? Icons.chevron_left : Icons.chevron_right,
            color: const Color(0xFF4A4C52), size: 20),
      ),
    );
  }

  Widget _landscapeLayout(Size size) {
    final hw = size.width * 0.34;
    return Column(children: [
      _topBar(),
      if (_showText) _textRow(),
      Expanded(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(6, 0, 6, 8),
          child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            _half(_leftHalf, _leftOpen, hw, true),
            _sideTab(
                _leftOpen, true, () => setState(() => _leftOpen = !_leftOpen)),
            Expanded(child: _mousePanel(clutchH: 50, buttonsH: 62)),
            _sideTab(_rightOpen, false,
                () => setState(() => _rightOpen = !_rightOpen)),
            _half(_rightHalf, _rightOpen, hw, false),
          ]),
        ),
      ),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final land = size.width > size.height;
    if (land != _landscape) {
      _landscape = land;
      if (_moving) _startMove(); // re-zero after rotating
    }
    return Scaffold(
      backgroundColor: _bg,
      resizeToAvoidBottomInset: true,
      body: SafeArea(
        bottom: false,
        child: land ? _landscapeLayout(size) : _portrait(size),
      ),
    );
  }
}

/// A box that reports pointer down/up and redraws while pressed.
class _PressBox extends StatefulWidget {
  final VoidCallback onDown;
  final VoidCallback onUp;
  final Widget Function(bool pressed) builder;
  const _PressBox(
      {required this.onDown, required this.onUp, required this.builder});

  @override
  State<_PressBox> createState() => _PressBoxState();
}

class _PressBoxState extends State<_PressBox> {
  bool _pressed = false;

  void _up() {
    if (!_pressed) return;
    setState(() => _pressed = false);
    widget.onUp();
  }

  @override
  void dispose() {
    if (_pressed) widget.onUp();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: (_) {
        setState(() => _pressed = true);
        widget.onDown();
      },
      onPointerUp: (_) => _up(),
      onPointerCancel: (_) => _up(),
      child: widget.builder(_pressed),
    );
  }
}
