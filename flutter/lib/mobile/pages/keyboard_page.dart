// PhoneKB: "模拟键盘" — use the phone as a keyboard for a remote PC.
//
// The session is keyboard-only (see `LoginConfigHandler::keyboard_only` in Rust): it sends real
// key down/up events (USB HID codes, map mode) and drops video/audio without decoding, and never
// sends fps / quality / resolution / privacy options. So another device (e.g. a tablet) can keep
// viewing and controlling the same PC at the same time without being disturbed.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

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
    // Favorites first, keep the recent order otherwise.
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
          Text('把手机当成电脑的键盘',
              style: theme.textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.bold)),
          const SizedBox(height: 6),
          Text(
            '只发送按键，不接收画面和声音，不改电脑的分辨率和画质。'
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
                  labelText: '电脑的 RustDesk ID',
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
              child: Text('还没有连接过的设备，在上面输入电脑的 ID。',
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
// Session page: the keyboard
// ============================================================================

class _K {
  final String label;
  final String sub; // shifted symbol shown small
  final int code; // USB HID usage (page 7)
  final bool isMod;
  final int flex; // width in quarter keys
  const _K(this.label, this.code, {this.sub = '', this.flex = 4})
      : isMod = false;
  const _K.mod(this.label, this.code, {this.flex = 4})
      : sub = '',
        isMod = true;
}

// HID usages
const _ctrl = 0xE0, _shift = 0xE1, _alt = 0xE2, _win = 0xE3;
const _esc = 0x29, _tab = 0x2B, _caps = 0x39, _enter = 0x28, _bksp = 0x2A;
const _space = 0x2C, _del = 0x4C, _end = 0x4D, _f4 = 0x3D;
int _letter(String c) => 0x04 + c.toLowerCase().codeUnitAt(0) - 0x61;

final List<List<_K>> _rows = [
  [
    const _K('Esc', _esc),
    for (var i = 1; i <= 12; i++) _K('F$i', 0x3A + i - 1),
    const _K('PrtSc', 0x46),
    const _K('Ins', 0x49),
    const _K('Home', 0x4A),
    const _K('End', 0x4D),
    const _K('PgUp', 0x4B),
    const _K('PgDn', 0x4E),
    const _K('Del', _del),
  ],
  [
    const _K('`', 0x35, sub: '~'),
    for (var i = 0; i < 9; i++) _K('${i + 1}', 0x1E + i, sub: '!@#\$%^&*('[i]),
    const _K('0', 0x27, sub: ')'),
    const _K('-', 0x2D, sub: '_'),
    const _K('=', 0x2E, sub: '+'),
    const _K('⌫', _bksp, flex: 8),
  ],
  [
    const _K('Tab', _tab, flex: 6),
    for (final c in 'QWERTYUIOP'.split('')) _K(c, _letter(c)),
    const _K('[', 0x2F, sub: '{'),
    const _K(']', 0x30, sub: '}'),
    const _K('\\', 0x31, sub: '|', flex: 6),
  ],
  [
    const _K('Caps', _caps, flex: 7),
    for (final c in 'ASDFGHJKL'.split('')) _K(c, _letter(c)),
    const _K(';', 0x33, sub: ':'),
    const _K("'", 0x34, sub: '"'),
    const _K('Enter', _enter, flex: 9),
  ],
  [
    const _K.mod('Shift', _shift, flex: 9),
    for (final c in 'ZXCVBNM'.split('')) _K(c, _letter(c)),
    const _K(',', 0x36, sub: '<'),
    const _K('.', 0x37, sub: '>'),
    const _K('/', 0x38, sub: '?'),
    const _K('↑', 0x52),
    const _K.mod('Shift', _shift, flex: 7),
  ],
  [
    const _K.mod('Ctrl', _ctrl, flex: 5),
    const _K.mod('Win', _win, flex: 5),
    const _K.mod('Alt', _alt, flex: 5),
    const _K('', _space, flex: 23),
    const _K.mod('Alt', _alt, flex: 5),
    const _K.mod('Ctrl', _ctrl, flex: 5),
    const _K('←', 0x50),
    const _K('↓', 0x51),
    const _K('→', 0x4F),
  ],
];

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
  bool _showText = false;

  SessionID get _sid => gFFI.sessionId;

  // ---- key state ----
  final Map<int, int> _heldCount = {}; // modifier -> fingers on it
  final Set<int> _chordUsed = {}; // held modifiers already combined with a key
  final Set<int> _latched = {}; // tapped once: applies to the next key
  final Set<int> _locked = {}; // tapped twice: applies until tapped again
  final Set<int> _sentMods = {}; // modifiers currently down on the PC
  final Set<int> _downKeys = {}; // normal keys currently down on the PC
  final Set<int> _pressedUi = {}; // keys drawn as pressed
  bool _caps = false;
  Timer? _repeatTimer;
  int _repeatCode = 0;

  Set<int> get _held =>
      _heldCount.entries.where((e) => e.value > 0).map((e) => e.key).toSet();

  @override
  void initState() {
    super.initState();
    SystemChrome.setPreferredOrientations(
        [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    gFFI.ffiModel.updateEventListener(_sid, widget.id);
    gFFI.start(widget.id, keyboardOnly: true);
    WakelockManager.enable(_uniqueKey);
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) _releaseAll();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _releaseAll();
    unawaited(bind.sessionClose(sessionId: _sid));
    super.dispose();
    () async {
      await gFFI.close();
      gFFI.dialogManager.dismissAll();
      await SystemChrome.setPreferredOrientations([]);
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.manual,
          overlays: SystemUiOverlay.values);
      WakelockManager.disable(_uniqueKey);
    }();
    _textCtl.dispose();
  }

  // ---- sending ----

  void _send(int usb, bool down) {
    bind.sessionHandleFlutterKeyEvent(
      sessionId: _sid,
      character: '',
      usbHid: usb,
      lockModes: _caps ? (1 << 1) : 0, // CAPS_LOCK bit, see keyboard.rs
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

  void _keyDown(int code) {
    final held = _held;
    _chordUsed.addAll(held);
    _modsDown({...held, ..._latched, ..._locked});
    if (code == _caps) _caps = !_caps;
    _send(code, true);
    _downKeys.add(code);
    // The PC does not auto-repeat injected keys, so repeat like a real keyboard does.
    _repeatTimer?.cancel();
    _repeatCode = code;
    if (code != _caps) {
      _repeatTimer = Timer(const Duration(milliseconds: 400), () {
        _repeatTimer = Timer.periodic(const Duration(milliseconds: 40), (_) {
          if (_downKeys.contains(_repeatCode)) _send(_repeatCode, true);
        });
      });
    }
  }

  void _keyUp(int code) {
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
      // Unicode text, Chinese included, typed on the PC as-is.
      bind.sessionInputString(sessionId: _sid, value: t);
      _textCtl.clear();
    }
    if (enter) {
      Future.delayed(const Duration(milliseconds: 80), () => _combo([], _enter));
    }
  }

  // ---- UI ----

  static const _bg = Color(0xFF111214);
  static const _keyColor = Color(0xFF2E3036);
  static const _modColor = Color(0xFF23252A);
  static const _downColor = Color(0xFF0A84FF);
  static const _latchColor = Color(0xFF0A5FB8);
  static const _lockColor = Color(0xFFD9822B);
  static const _textColor = Color(0xFFF2F2F7);
  static const _subColor = Color(0xFF8E8E93);

  Color _colorOf(_K k) {
    if (k.isMod) {
      if (_held.contains(k.code)) return _downColor;
      if (_locked.contains(k.code)) return _lockColor;
      if (_latched.contains(k.code)) return _latchColor;
      return _modColor;
    }
    if (_pressedUi.contains(k.code)) return _downColor;
    if (k.code == _caps && _caps) return _lockColor;
    return _keyColor;
  }

  Widget _key(_K k, double h) {
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
              _pressedUi.add(k.code);
              _keyDown(k.code);
            }
          });
        },
        onPointerUp: (_) => setState(() {
          if (k.isMod) {
            _modUp(k.code);
          } else {
            _pressedUi.remove(k.code);
            _keyUp(k.code);
          }
        }),
        onPointerCancel: (_) => setState(() {
          if (k.isMod) {
            _modUp(k.code);
          } else {
            _pressedUi.remove(k.code);
            _keyUp(k.code);
          }
        }),
        child: Container(
          margin: const EdgeInsets.all(2),
          decoration: BoxDecoration(
            color: _colorOf(k),
            borderRadius: BorderRadius.circular(7),
          ),
          alignment: Alignment.center,
          child: k.sub.isEmpty
              ? Text(k.label,
                  maxLines: 1,
                  style: TextStyle(
                    color: _textColor,
                    fontSize: (k.label.length > 2 ? h * 0.26 : h * 0.36)
                        .clamp(9.0, 26.0),
                    fontWeight: k.isMod ? FontWeight.w600 : FontWeight.w400,
                  ))
              : Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                  Text(k.sub,
                      style: TextStyle(
                          color: _subColor,
                          fontSize: (h * 0.22).clamp(8.0, 16.0),
                          height: 1.0)),
                  Text(k.label,
                      style: TextStyle(
                          color: _textColor,
                          fontSize: (h * 0.30).clamp(9.0, 22.0),
                          height: 1.05)),
                ]),
        ),
      ),
    );
  }

  Widget _pill(String text, VoidCallback onTap) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 3),
      child: Material(
        color: const Color(0xFF2A2C31),
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () {
            HapticFeedback.selectionClick();
            onTap();
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Text(text,
                style: const TextStyle(color: _textColor, fontSize: 13)),
          ),
        ),
      ),
    );
  }

  Widget _topBar() {
    return Row(children: [
      IconButton(
        icon: const Icon(Icons.close, color: _textColor),
        tooltip: '断开',
        onPressed: () => Navigator.pop(context),
      ),
      Obx(() {
        final ok = gFFI.ffiModel.pi.isSet.value;
        final kbOff = gFFI.ffiModel.permissions['keyboard'] == false;
        final color = !ok
            ? const Color(0xFFFF9F0A)
            : (kbOff ? const Color(0xFFFF453A) : const Color(0xFF30D158));
        final text = !ok
            ? '正在连接 ${formatID(widget.id)}…'
            : (kbOff
                ? '已连接，但电脑端关闭了键盘权限'
                : '已连接 ${formatID(widget.id)}（仅键盘）');
        return Row(children: [
          Container(
              width: 9,
              height: 9,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
          const SizedBox(width: 8),
          Text(text, style: const TextStyle(color: _textColor, fontSize: 13)),
        ]);
      }),
      const Spacer(),
      _pill(_showText ? '收起文字' : '文字输入',
          () => setState(() => _showText = !_showText)),
    ]);
  }

  Widget _shortcutBar() {
    final sc = <(String, VoidCallback)>[
      ('中/英', () => _tapMod(_shift)),
      ('切输入法', () => _combo([_win], _space)),
      ('Ctrl+Alt+Del', () => bind.sessionCtrlAltDel(sessionId: _sid)),
      ('锁屏', () => bind.sessionLockScreen(sessionId: _sid)),
      ('任务管理器', () => _combo([_ctrl, _shift], _esc)),
      ('Alt+Tab', () => _combo([_alt], _tab)),
      ('回桌面', () => _combo([_win], _letter('d'))),
      ('复制', () => _combo([_ctrl], _letter('c'))),
      ('粘贴', () => _combo([_ctrl], _letter('v'))),
      ('剪切', () => _combo([_ctrl], _letter('x'))),
      ('撤销', () => _combo([_ctrl], _letter('z'))),
      ('全选', () => _combo([_ctrl], _letter('a'))),
      ('保存', () => _combo([_ctrl], _letter('s'))),
      ('截图', () => _combo([_win, _shift], _letter('s'))),
      ('关窗口', () => _combo([_alt], _f4)),
      ('资源管理器', () => _combo([_win], _letter('e'))),
    ];
    return SizedBox(
      height: 34,
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: sc.map((e) => Center(child: _pill(e.$1, e.$2))).toList(),
      ),
    );
  }

  Widget _textRow() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(children: [
        Expanded(
          child: TextField(
            controller: _textCtl,
            style: const TextStyle(color: _textColor, fontSize: 14),
            decoration: InputDecoration(
              hintText: '在这里打字（中文也行），一次性发到电脑',
              hintStyle: const TextStyle(color: _subColor),
              filled: true,
              fillColor: _keyColor,
              isDense: true,
              border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide.none),
            ),
            onSubmitted: (_) => _sendText(),
          ),
        ),
        _pill('发送', _sendText),
        _pill('发送+回车', () => _sendText(enter: true)),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      resizeToAvoidBottomInset: true,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(4, 0, 4, 4),
          child: Column(children: [
            SizedBox(height: 40, child: _topBar()),
            _shortcutBar(),
            if (_showText) _textRow(),
            Expanded(
              child: LayoutBuilder(builder: (context, c) {
                // Function row is a bit shorter than the others.
                final unit = c.maxHeight / (_rows.length - 0.3);
                return Column(
                  children: [
                    for (var i = 0; i < _rows.length; i++)
                      SizedBox(
                        height: i == 0 ? unit * 0.7 : unit,
                        child: Row(
                          children: _rows[i]
                              .map((k) => _key(k, i == 0 ? unit * 0.8 : unit))
                              .toList(),
                        ),
                      ),
                  ],
                );
              }),
            ),
          ]),
        ),
      ),
    );
  }
}
