// PhoneKB: phone -> tablet relay, end to end over a real local TCP socket.
//   flutter test test/phonekb_relay_test.dart
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/mobile/phonekb_relay.dart';

void main() {
  test('pairing, keys, mouse, text and release on disconnect', () async {
    final keys = <String>[];
    final mice = <Map<String, dynamic>>[];
    final texts = <String>[];
    final toasts = <String>[];
    var cad = 0;
    final sink = RelaySink(
      key: (u, l, d) => keys.add('$u:${d ? 'down' : 'up'}:$l'),
      mouse: (m) => mice.add(m),
      text: (v) => texts.add(v),
      ctrlAltDel: () => cad++,
      lockScreen: () {},
      toast: (m, _) => toasts.add(m),
    );
    const port = 21390;
    final server = PhoneKbRelayServer.test(
        peerId: '100.97.81.22', sink: sink, pin: '482913', port: port);
    await server.start();

    final store = <String, String>{};
    Future<void> waitFor(bool Function() ok) async {
      for (var i = 0; i < 100 && !ok(); i++) {
        await Future.delayed(const Duration(milliseconds: 20));
      }
      expect(ok(), isTrue);
    }

    // First connect: no PIN saved -> tablet shows the PIN, phone must ask.
    final c = PhoneKbRelayClient('127.0.0.1',
        port: port,
        loadOpt: (k) => store[k] ?? '',
        saveOpt: (k, v) => store[k] = v);
    await c.connect();
    await waitFor(() => c.state.value == RelayState.needPin);
    expect(toasts.last, contains('482913'));
    expect(c.tabletPeer, '100.97.81.22');

    // Wrong PIN is refused.
    c.submitPin('000000');
    await waitFor(() => c.pinRejected);
    expect(c.state.value, RelayState.needPin);

    // Right PIN connects and is remembered.
    c.submitPin('482913');
    await waitFor(() => c.state.value == RelayState.connected);
    expect(store.values, contains('482913'));

    c.key(0x04, 2, true); // 'a' down, caps bit
    c.key(0x04, 2, false);
    c.mouse({'type': 'move_relative', 'x': '5', 'y': '-3'});
    c.text('你好');
    c.ctrlAltDel();
    await waitFor(() => cad == 1);
    expect(keys, ['4:down:2', '4:up:2']);
    expect(mice.single['type'], 'move_relative');
    expect(texts.single, '你好');

    // Phone vanishes with Shift and the left button held: tablet lets go.
    c.key(0xE1, 0, true);
    c.mouse({'type': 'down', 'buttons': 'left'});
    await waitFor(() => keys.length == 3 && mice.length == 2);
    c.close();
    await waitFor(() => keys.length == 4 && mice.length == 3);
    expect(keys.last, '225:up:0');
    expect(mice.last, {'type': 'up', 'buttons': 'left'});

    // Reconnect: the saved PIN is used without asking again.
    final c2 = PhoneKbRelayClient('127.0.0.1',
        port: port,
        loadOpt: (k) => store[k] ?? '',
        saveOpt: (k, v) => store[k] = v);
    await c2.connect();
    await waitFor(() => c2.state.value == RelayState.connected);
    c2.close();
    await server.stop();
  });

  test('probe finds the tablet and reads its name', () async {
    final server = PhoneKbRelayServer.test(
        peerId: 'PC',
        sink: RelaySink(
            key: (_, __, ___) {},
            mouse: (_) {},
            text: (_) {},
            ctrlAltDel: () {},
            lockScreen: () {},
            toast: (_, __) {}),
        pin: '111111',
        port: kPhoneKbRelayPort);
    await server.start();
    final t = await probeTablet('127.0.0.1');
    expect(t, isNotNull);
    expect(t!.peer, 'PC');
    await server.stop();
  });
}
