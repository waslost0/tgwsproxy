// Purpose: minimal base model layer used by every screen.
import 'package:flutter/foundation.dart';

import '../model/app_model.dart';

abstract class IBaseModelListener {
  void onModelUpdated();

  void onModelError(String error);

  void onModelMessage(String message);
}

/// ChangeNotifier that ignores notifications after dispose.
abstract class SafeChangeNotifier extends ChangeNotifier {
  bool _isDisposed = false;

  bool get isDisposed => _isDisposed;

  @override
  void dispose() {
    _isDisposed = true;
    super.dispose();
  }

  void safeNotify() {
    if (!_isDisposed) notifyListeners();
  }
}

/// Shared model state: safe notifications, screen errors/messages.
abstract class BaseModel extends SafeChangeNotifier {
  BaseModel({this.appModel});

  final AppModel? appModel;
  final List<IBaseModelListener> _modelListeners = [];
  String? _lastError;

  String? get lastError => _lastError;
  bool get hasError => _lastError != null;

  void addModelListener(IBaseModelListener listener) {
    if (_modelListeners.contains(listener)) return;
    _modelListeners.add(listener);
    addListener(listener.onModelUpdated);
  }

  void removeModelListener(IBaseModelListener listener) {
    if (!_modelListeners.remove(listener)) return;
    removeListener(listener.onModelUpdated);
  }

  void notifyModelListeners({bool resetError = true}) {
    if (isDisposed) return;
    if (resetError) _lastError = null;
    notifyListeners();
  }

  void addError(String? error, {bool saveError = true}) {
    if (error == null) return;
    if (saveError) _lastError = error;
    if (isDisposed) return;
    notifyListeners();
    for (final listener in _modelListeners) {
      listener.onModelError(error);
    }
  }

  void addMessage(String message) {
    if (isDisposed) return;
    notifyListeners();
    for (final listener in _modelListeners) {
      listener.onModelMessage(message);
    }
  }

  void clearError() => _lastError = null;
}
