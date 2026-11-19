// Purpose: Logs view-model and filtering.
import '../../core/base/base_model.dart';

enum LogFilter {
  all('Все'),
  warning('Warning'),
  error('Error');

  const LogFilter(this.label);

  final String label;
}

class LogsWM extends BaseModel {
  LogFilter filter = LogFilter.all;
  final List<String> lines = [];

  List<String> get visibleLines => lines;

  void setFilter(LogFilter value) {
    filter = value;
    notifyModelListeners();
  }
}
