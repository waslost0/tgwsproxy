// Purpose: binds a BasePage to its BaseModel via provider, with safe dispose.
import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';

import 'base_model.dart';
import 'base_page.dart';

mixin BasePageModelMixin<T extends BasePage, TModel extends BaseModel>
    on BasePageState<T>
    implements IBaseModelListener {
  /// Model is created on first use, when [context] and providers are ready.
  late final TModel model = createModel();

  bool shouldDecorateToModelProvider = true;
  bool shouldDisposeModel = true;

  TModel createModel();

  @override
  void initState() {
    super.initState();
    model.addModelListener(this);
  }

  @override
  void dispose() {
    model.removeModelListener(this);
    if (shouldDisposeModel) model.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (shouldDecorateToModelProvider) {
      return ChangeNotifierProvider.value(
        value: model,
        child: Consumer<TModel>(
          builder: (context, _, _) => super.build(context),
        ),
      );
    }
    return super.build(context);
  }

  @override
  void onModelUpdated() {}

  @override
  void onModelError(String error) {
    showError(error);
  }

  @override
  void onModelMessage(String message) {
    showMessage(message);
  }
}
