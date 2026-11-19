// Purpose: Connection screen state, driven by the Kotlin ProxyBridge.
import '../../core/base/base_model.dart';
import '../../core/proxy/proxy_repository.dart';

enum ProxyStatus { stopped, starting, running, stopping }

/// Maps [ProxyRepository] snapshots to the connection screen.
class ConnectionWM extends BaseModel {
  ConnectionWM(this._repository) {
    _repository.addListener(_sync);
    _sync();
  }

  final ProxyRepository _repository;

  ProxyStatus status = ProxyStatus.stopped;
  String? error;
  String host = '127.0.0.1';
  int port = 1443;
  int connections = 0;
  int bytesUp = 0;
  int bytesDown = 0;
  String route = '—';

  bool get running => status == ProxyStatus.running;
  bool get busy =>
      status == ProxyStatus.starting || status == ProxyStatus.stopping;
  String get address => '$host:$port';
  String get traffic => '${formatBytes(bytesUp)} / ${formatBytes(bytesDown)}';

  void _sync() {
    final state = _repository.state;
    host = state.host;
    port = state.port;
    connections = state.activeConnections;
    bytesUp = state.bytesUp;
    bytesDown = state.bytesDown;
    route = state.displayRoute;
    error = _repository.error ?? state.error;

    if (state.starting) {
      status = ProxyStatus.starting;
    } else if (state.running) {
      status = ProxyStatus.running;
    } else {
      status = ProxyStatus.stopped;
    }
    notifyModelListeners();
  }

  Future<void> toggle() async {
    if (busy) return;
    if (running || status == ProxyStatus.starting) {
      status = ProxyStatus.stopping;
      notifyModelListeners();
      await _repository.stop();
    } else {
      status = ProxyStatus.starting;
      notifyModelListeners();
      await _repository.start();
    }
  }

  @override
  void dispose() {
    _repository.removeListener(_sync);
    super.dispose();
  }
}

String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes Б';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} КБ';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} МБ';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} ГБ';
}
