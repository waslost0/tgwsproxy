import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:tgwsproxy/core/proxy/proxy_repository.dart';
import 'package:tgwsproxy/features/connection/connection_page.dart';

import 'support/fake_proxy_backend.dart';

void main() {
  testWidgets('connection screen renders the idle state', (tester) async {
    await tester.pumpWidget(
      ChangeNotifierProvider(
        create: (_) => ProxyRepository(),
        child: const MaterialApp(home: ConnectionPage()),
      ),
    );

    expect(find.text('TG WS Proxy'), findsOneWidget);
    expect(find.text('Запустить'), findsOneWidget);

    await tester.drag(find.byType(ListView), const Offset(0, -400));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('127.0.0.1:1443'), findsOneWidget);
  });

  testWidgets('start button drives the proxy backend', (tester) async {
    final backend = FakeProxyBackend();
    final repository = ProxyRepository(backend: backend);
    await repository.init();

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: repository,
        child: const MaterialApp(home: ConnectionPage()),
      ),
    );

    await tester.tap(find.text('Запустить'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(backend.running, isTrue);
    expect(repository.state.running, isTrue);
    expect(find.text('Остановить'), findsOneWidget);
    repository.dispose();
  });
}
