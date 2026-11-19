// Purpose: full screen scaffold from base-flutter (pre-Elementary), stripped
// of auth, drawer, backend access and WTS-only widgets.
import 'package:material_ui/material_ui.dart';

import '../ui/app_toast.dart';
import 'keyboard_dismisser.dart';

abstract class BasePage extends StatefulWidget {
  const BasePage({super.key, this.title});

  final String? title;
}

abstract class BasePageState<T extends BasePage> extends State<T> {
  final GlobalKey<ScaffoldState> scaffoldKey = GlobalKey<ScaffoldState>();

  bool get shouldBuildScaffold => true;
  bool get isSafeAreaEnabled => false;
  bool get extendBodyBehindAppBar => false;
  bool get resizeToAvoidBottomInset => true;

  bool _isLoading = false;
  bool _hideContentWhileLoading = false;

  bool get isLoading => _isLoading;

  @override
  Widget build(BuildContext context) {
    var body = buildBody();
    body = decorateBody(body);
    if (isSafeAreaEnabled) body = SafeArea(child: body);
    var scaffold = buildScaffold(body);
    scaffold = decorateScaffold(scaffold);
    return decorateKeyboardUnfocusing(scaffold);
  }

  @protected
  Widget buildScaffold(Widget body) {
    if (!shouldBuildScaffold) return body;
    return Scaffold(
      key: scaffoldKey,
      extendBodyBehindAppBar: extendBodyBehindAppBar,
      resizeToAvoidBottomInset: resizeToAvoidBottomInset,
      appBar: buildAppBar(),
      body: body,
      floatingActionButton: buildFloatingActionButton(),
    );
  }

  @protected
  PreferredSizeWidget? buildAppBar() {
    return AppBar(
      title: buildAppBarTitle(),
      leading: buildAppBarLeading(),
      actions: buildAppBarActions(),
      bottom: buildAppBarBottom(),
    );
  }

  @protected
  Widget? buildAppBarTitle() {
    final title = widget.title;
    return title == null ? null : Text(title);
  }

  @protected
  Widget? buildAppBarLeading() {
    return Navigator.canPop(context) ? const BackButton() : null;
  }

  @protected
  List<Widget>? buildAppBarActions() => null;

  @protected
  PreferredSizeWidget? buildAppBarBottom() => null;

  @protected
  Widget? buildFloatingActionButton() => null;

  @protected
  Widget decorateBody(Widget body) {
    if (!_isLoading) return body;
    return Stack(
      fit: StackFit.expand,
      children: [if (!_hideContentWhileLoading) body, buildLoadingIndicator()],
    );
  }

  @protected
  Widget decorateKeyboardUnfocusing(Widget child) {
    return KeyboardDismisser(child: child);
  }

  @protected
  Widget decorateScaffold(Widget scaffold) => scaffold;

  @protected
  Widget buildLoadingIndicator() {
    return const ColoredBox(
      color: Color(0x66000000),
      child: Center(child: CircularProgressIndicator()),
    );
  }

  /// Override to build the screen content.
  Widget buildBody();

  void showLoadingIndicator({bool hideContent = false}) {
    if (!mounted) return;
    setState(() {
      _isLoading = true;
      _hideContentWhileLoading = hideContent;
    });
  }

  void hideLoadingIndicator() {
    if (!mounted) return;
    setState(() {
      _isLoading = false;
      _hideContentWhileLoading = false;
    });
  }

  void showMessage(String? message) => AppToast.showMessage(message);

  void showError(String? error) => AppToast.showError(error);
}
