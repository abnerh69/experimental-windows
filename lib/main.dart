// Demo EXPERIMENTAL de la API oficial de windowing de Flutter (canal main).
// La API es @internal y cambiará sin aviso, incluso entre parches.
// Requiere: canal main + `flutter config --enable-windowing`.
//
// TODO: retirar estos ignores cuando la API sea estable.
// ignore_for_file: invalid_use_of_internal_member
// ignore_for_file: implementation_imports

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/src/widgets/_window.dart';
import 'package:flutter/src/widgets/_window_positioner.dart';

/// Estado compartido entre TODAS las ventanas: un solo engine, un solo isolate.
final ValueNotifier<int> contadorCompartido = ValueNotifier<int>(0);

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runWidget(
    RegularWindow(
      controller: RegularWindowController(
        size: const Size(920, 640),
        constraints: const BoxConstraints(minWidth: 720, minHeight: 500),
        title: 'Windowing Demo · Ventana principal',
        delegate: _CerrarAppAlDestruir(),
      ),
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData(colorSchemeSeed: Colors.indigo),
        home: const PaginaPrincipal(),
      ),
    ),
  );
}

// ---------------------------------------------------------------------------
// Delegates: reaccionan al ciclo de vida de cada ventana.
// El comportamiento por defecto de onWindowCloseRequested es destruir la
// ventana; aquí solo interesa limpiar al destruirse.
// ---------------------------------------------------------------------------

class _CerrarAppAlDestruir with RegularWindowControllerDelegate {
  @override
  void onWindowDestroyed() {
    super.onWindowDestroyed();
    exit(0); // Cerrar la ventana principal termina la aplicación.
  }
}

class _AlDestruirRegular with RegularWindowControllerDelegate {
  _AlDestruirRegular(this.alDestruir);
  final VoidCallback alDestruir;

  @override
  void onWindowDestroyed() {
    alDestruir();
    super.onWindowDestroyed();
  }
}

class _AlDestruirDialogo with DialogWindowControllerDelegate {
  _AlDestruirDialogo(this.alDestruir);
  final VoidCallback alDestruir;

  @override
  void onWindowDestroyed() {
    alDestruir();
    super.onWindowDestroyed();
  }
}

class _AlDestruirTooltip with TooltipWindowControllerDelegate {
  _AlDestruirTooltip(this.alDestruir);
  final VoidCallback alDestruir;

  @override
  void onWindowDestroyed() {
    alDestruir();
    super.onWindowDestroyed();
  }
}

class _AlDestruirPopup with PopupWindowControllerDelegate {
  _AlDestruirPopup(this.alDestruir);
  final VoidCallback alDestruir;

  @override
  void onWindowDestroyed() {
    alDestruir();
    super.onWindowDestroyed();
  }
}

// ---------------------------------------------------------------------------
// Ventana principal
// ---------------------------------------------------------------------------

class PaginaPrincipal extends StatefulWidget {
  const PaginaPrincipal({super.key});

  @override
  State<PaginaPrincipal> createState() => _PaginaPrincipalState();
}

class _PaginaPrincipalState extends State<PaginaPrincipal> {
  final GlobalKey _botonPopup = GlobalKey();
  final GlobalKey _botonTooltip = GlobalKey();

  WindowEntry? _popupAbierto;
  WindowEntry? _tooltipAbierto;
  int _secuenciaRegulares = 0;

  /// Rectángulo global (en coordenadas de esta ventana) del widget con [key].
  Rect _rectDe(GlobalKey key) {
    final RenderBox caja = key.currentContext!.findRenderObject()! as RenderBox;
    return caja.localToGlobal(Offset.zero) & caja.size;
  }

  // --------------------------- Ventana regular ----------------------------

  void _crearVentanaRegular() {
    final WindowRegistry registro = WindowRegistry.of(context);
    final int numero = ++_secuenciaRegulares;

    late final WindowEntry entrada;
    final RegularWindowController controlador = RegularWindowController(
      size: const Size(480, 380),
      title: 'Ventana regular #$numero',
      delegate: _AlDestruirRegular(() => registro.unregister(entrada)),
    );
    entrada = WindowEntry(
      controller: controlador,
      builder: (_) => ContenidoVentanaRegular(numero: numero),
    );
    registro.register(entrada);
  }

  // -------------------------------- Popup ---------------------------------

  void _alternarPopup() {
    if (_popupAbierto != null) {
      _popupAbierto!.controller.destroy(); // El delegate limpia el estado.
      return;
    }

    final WindowRegistry registro = WindowRegistry.of(context);
    late final WindowEntry entrada;
    final PopupWindowController controlador = PopupWindowController(
      parent: WindowScope.of(context),
      anchorRect: _rectDe(_botonPopup),
      positioner: const WindowPositioner(
        parentAnchor: WindowPositionerAnchor.bottomLeft,
        childAnchor: WindowPositionerAnchor.topLeft,
        offset: Offset(0, 6),
      ),
      delegate: _AlDestruirPopup(() {
        registro.unregister(entrada);
        if (mounted) {
          setState(() => _popupAbierto = null);
        }
      }),
    );
    entrada = WindowEntry(
      controller: controlador,
      builder: (_) => const _ContenidoPopup(),
    );
    registro.register(entrada);
    setState(() => _popupAbierto = entrada);
  }

  // ------------------------------- Tooltip --------------------------------

  void _alternarTooltip() {
    if (_tooltipAbierto != null) {
      _tooltipAbierto!.controller.destroy();
      return;
    }

    final WindowRegistry registro = WindowRegistry.of(context);
    late final WindowEntry entrada;
    final TooltipWindowController controlador = TooltipWindowController(
      parent: WindowScope.of(context),
      anchorRect: _rectDe(_botonTooltip),
      positioner: const WindowPositioner(
        parentAnchor: WindowPositionerAnchor.right,
        childAnchor: WindowPositionerAnchor.left,
        offset: Offset(8, 0),
      ),
      delegate: _AlDestruirTooltip(() {
        registro.unregister(entrada);
        if (mounted) {
          setState(() => _tooltipAbierto = null);
        }
      }),
    );
    entrada = WindowEntry(
      controller: controlador,
      builder: (_) => const _ContenidoTooltip(),
    );
    registro.register(entrada);
    setState(() => _tooltipAbierto = entrada);
  }

  // ------------------------------- Diálogos -------------------------------

  void _crearDialogo({required bool modal}) {
    final WindowRegistry registro = WindowRegistry.of(context);

    late final WindowEntry entrada;
    final DialogWindowController controlador = DialogWindowController(
      size: const Size(400, 260),
      title: modal ? 'Diálogo modal' : 'Diálogo sin padre (modeless)',
      // Con parent, la plataforma lo trata como modal de esa ventana.
      parent: modal ? WindowScope.of(context) : null,
      delegate: _AlDestruirDialogo(() => registro.unregister(entrada)),
    );
    entrada = WindowEntry(
      controller: controlador,
      builder: (_) => _ContenidoDialogo(modal: modal),
    );
    registro.register(entrada);
  }

  void _mostrarShowDialog() {
    // Con windowing activo, showDialog crea una ventana nativa hija
    // automáticamente: no hay que tocar nada del código Material clásico.
    showDialog<void>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('showDialog de Material'),
        content: const Text(
          'Este diálogo usa el showDialog de siempre.\n\n'
          'Con la bandera enable-windowing, Flutter lo renderiza en una '
          'ventana nativa hija en lugar de una ruta superpuesta.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cerrar'),
          ),
        ],
      ),
    );
  }

  // --------------------------------- UI -----------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Flutter Windowing Demo (experimental)')),
      body: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Expanded(
            flex: 55,
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Text('Crear ventanas',
                      style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    icon: const Icon(Icons.window_outlined),
                    label: const Text('Nueva ventana regular'),
                    onPressed: _crearVentanaRegular,
                  ),
                  const SizedBox(height: 8),
                  FilledButton.tonalIcon(
                    key: _botonPopup,
                    icon: const Icon(Icons.menu_open),
                    label: Text(_popupAbierto == null
                        ? 'Mostrar popup'
                        : 'Ocultar popup'),
                    onPressed: _alternarPopup,
                  ),
                  const SizedBox(height: 8),
                  FilledButton.tonalIcon(
                    key: _botonTooltip,
                    icon: const Icon(Icons.info_outline),
                    label: Text(_tooltipAbierto == null
                        ? 'Mostrar tooltip'
                        : 'Ocultar tooltip'),
                    onPressed: _alternarTooltip,
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    icon: const Icon(Icons.web_asset),
                    label: const Text('Diálogo modal (con parent)'),
                    onPressed: () => _crearDialogo(modal: true),
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    icon: const Icon(Icons.web_asset_off),
                    label: const Text('Diálogo sin padre (modeless)'),
                    onPressed: () => _crearDialogo(modal: false),
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    icon: const Icon(Icons.chat_bubble_outline),
                    label: const Text('showDialog de Material'),
                    onPressed: _mostrarShowDialog,
                  ),
                  const SizedBox(height: 24),
                  const _TarjetaContador(),
                ],
              ),
            ),
          ),
          const VerticalDivider(width: 1),
          const Expanded(flex: 45, child: _ListaVentanas()),
        ],
      ),
    );
  }
}

/// Contador compartido: se ve y se incrementa desde cualquier ventana.
class _TarjetaContador extends StatelessWidget {
  const _TarjetaContador();

  @override
  Widget build(BuildContext context) {
    return Card.outlined(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: ValueListenableBuilder<int>(
          valueListenable: contadorCompartido,
          builder: (BuildContext context, int valor, _) => Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  'Contador compartido (mismo isolate): $valor',
                  style: Theme.of(context).textTheme.bodyLarge,
                ),
              ),
              IconButton.filledTonal(
                icon: const Icon(Icons.add),
                onPressed: () => contadorCompartido.value++,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Ventanas secundarias registradas en el WindowRegistry (lo provee
/// WindowManager, que MaterialApp inserta automáticamente).
class _ListaVentanas extends StatelessWidget {
  const _ListaVentanas();

  String _tipo(BaseWindowController c) => switch (c) {
        RegularWindowController() => 'Regular',
        DialogWindowController() => 'Diálogo',
        TooltipWindowController() => 'Tooltip',
        PopupWindowController() => 'Popup',
        SatelliteWindowController() => 'Satélite',
      };

  @override
  Widget build(BuildContext context) {
    final WindowRegistry registro = WindowRegistry.of(context);
    return ListenableBuilder(
      listenable: registro,
      builder: (BuildContext context, _) {
        final List<WindowEntry> ventanas = registro.windows;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
              child: Text(
                'Ventanas secundarias: ${ventanas.length}',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            Expanded(
              child: ventanas.isEmpty
                  ? const Center(child: Text('Ninguna abierta'))
                  : ListView(
                      children: <Widget>[
                        for (final WindowEntry e in ventanas)
                          ListTile(
                            dense: true,
                            leading: const Icon(Icons.crop_square),
                            title: Text(_tipo(e.controller)),
                            subtitle:
                                Text('viewId: ${e.controller.rootView.viewId}'),
                            trailing: IconButton(
                              icon: const Icon(Icons.close),
                              tooltip: 'Destruir',
                              onPressed: e.controller.destroy,
                            ),
                          ),
                      ],
                    ),
            ),
          ],
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Contenido de las ventanas secundarias
// ---------------------------------------------------------------------------

class ContenidoVentanaRegular extends StatelessWidget {
  const ContenidoVentanaRegular({super.key, required this.numero});

  final int numero;

  @override
  Widget build(BuildContext context) {
    final BaseWindowController ventana = WindowScope.of(context);
    return Overlay.wrap(
      child: Scaffold(
        appBar: AppBar(title: Text('Ventana regular #$numero')),
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text('viewId: ${ventana.rootView.viewId}'),
              const SizedBox(height: 16),
              ValueListenableBuilder<int>(
                valueListenable: contadorCompartido,
                builder: (BuildContext context, int valor, _) =>
                    Text('Contador compartido: $valor',
                        style: Theme.of(context).textTheme.titleLarge),
              ),
              const SizedBox(height: 8),
              FilledButton.tonal(
                onPressed: () => contadorCompartido.value++,
                child: const Text('+1 desde esta ventana'),
              ),
              const SizedBox(height: 24),
              OutlinedButton(
                onPressed: ventana.destroy,
                child: const Text('Cerrar esta ventana'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ContenidoDialogo extends StatelessWidget {
  const _ContenidoDialogo({required this.modal});

  final bool modal;

  @override
  Widget build(BuildContext context) {
    return Overlay.wrap(
      child: FocusScope(
        autofocus: true,
        child: Scaffold(
          body: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  modal ? 'Diálogo modal' : 'Diálogo modeless',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 12),
                Expanded(
                  child: Text(
                    modal
                        ? 'Creado con DialogWindowController y parent. La '
                            'plataforma bloquea la interacción con la ventana '
                            'padre mientras esté abierto.'
                        : 'Creado con DialogWindowController sin parent: '
                            'flota de forma independiente y no bloquea nada.',
                  ),
                ),
                Align(
                  alignment: Alignment.bottomRight,
                  child: FilledButton(
                    onPressed: WindowScope.of(context).destroy,
                    child: const Text('Cerrar'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Los popups y tooltips no reciben tamaño: se ajustan a su contenido.
class _ContenidoPopup extends StatelessWidget {
  const _ContenidoPopup();

  @override
  Widget build(BuildContext context) {
    return Overlay.wrap(
      alwaysSizeToContent: true,
      child: IntrinsicWidth(
        child: Material(
          color: Theme.of(context).colorScheme.surfaceContainerHigh,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text('Popup nativo',
                    style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                const Text('Ventana anclada al botón,\n'
                    'posicionada con WindowPositioner.'),
                const SizedBox(height: 12),
                TextButton(
                  onPressed: WindowScope.of(context).destroy,
                  child: const Text('Cerrar'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ContenidoTooltip extends StatelessWidget {
  const _ContenidoTooltip();

  @override
  Widget build(BuildContext context) {
    return Overlay.wrap(
      alwaysSizeToContent: true,
      child: IntrinsicWidth(
        child: Material(
          color: const Color(0xE6303030),
          child: const Padding(
            padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Text(
              'Tooltip nativo: puede sobresalir\ndel borde de la ventana padre.',
              style: TextStyle(color: Colors.white, fontSize: 12),
            ),
          ),
        ),
      ),
    );
  }
}
