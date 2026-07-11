// Demo EXPERIMENTAL de la API oficial de windowing de Flutter (canal main).
// La API es @internal y cambiará sin aviso, incluso entre parches.
// Requiere: canal main + `flutter config --enable-windowing`.
//
// TODO: retirar estos ignores cuando la API sea estable.
// ignore_for_file: invalid_use_of_internal_member
// ignore_for_file: implementation_imports

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/src/widgets/_window.dart';
import 'package:flutter/src/widgets/_window_positioner.dart';

/// Estado compartido entre TODAS las ventanas: un solo engine, un solo isolate.
final ValueNotifier<int> contadorCompartido = ValueNotifier<int>(0);

/// Controladores cuya destrucción ya fue solicitada. Evita el doble destroy
/// y da un único punto de salida; en el canal main, destruir de más puede
/// abortar el VM (ver docs/popups-macos.md).
final Set<BaseWindowController> _destruccionSolicitada =
    <BaseWindowController>{};

/// Milisegundos entre solicitar la destrucción y ejecutarla. El clic de
/// cierre repinta la propia ventana (efecto ink) y encola un commit de
/// presentación en el run loop; destruir en el mismo turno del gesto le gana
/// a ese commit y el engine invoca un callback FFI ya cerrado (aborto del
/// VM). Diferir cede el run loop para que los commits — y la animación del
/// ink (~300 ms) — terminen antes del destroy.
const Duration _demoraDestruccion = Duration(milliseconds: 400);

void destruirSeguro(BaseWindowController controlador) {
  if (_destruccionSolicitada.add(controlador)) {
    Future<void>.delayed(_demoraDestruccion, controlador.destroy);
  }
}

/// Fases de una ventana emergente (popup/tooltip). Las emergentes se
/// redimensionan a su contenido justo tras crearse; destruirlas con ese
/// commit nativo pendiente dispara "Callback invoked after it has been
/// deleted" en el engine (carrera destroy ↔ ResizeSynchronizer). Se bloquea
/// el cierre hasta que la ventana se asienta.
enum _FaseEmergente { cerrado, abriendo, abierto, cerrando }

/// Suprime las dos aserciones de debug conocidas al cerrar el diálogo-ventana
/// fullscreen (docs/showdialog-macos.md). Cambiar a false para verlas íntegras.
const bool suprimirAsercionesConocidas = true;

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  if (suprimirAsercionesConocidas) {
    _instalarFiltroDeAsercionesConocidas();
  }
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

/// El framework (canal main) destruye la ventana del diálogo de forma
/// síncrona dentro de `_DialogWindowRoute.didPop`, con el Navigator aún
/// bloqueado (`_debugLocked`); eso bombea un frame anidado que desmonta el
/// navigator interno del diálogo en pleno pop y dispara dos aserciones de
/// debug NO fatales cada vez que se cierra el diálogo fullscreen. Este
/// filtro las reduce a una línea de log y deja pasar todo lo demás intacto.
void _instalarFiltroDeAsercionesConocidas() {
  final FlutterExceptionHandler? previo = FlutterError.onError;
  FlutterError.onError = (FlutterErrorDetails detalles) {
    final String texto = detalles.exceptionAsString();
    final String pila = detalles.stack?.toString() ?? '';
    final bool bloqueoNavigator = texto.contains("'!_debugLocked'") &&
        pila.contains('_DialogWindowRoute.didPop');
    final bool elementoDifunto =
        texto.contains('_ElementLifecycle.defunct') &&
            pila.contains('NavigatorState._cancelActivePointers');
    if (bloqueoNavigator || elementoDifunto) {
      debugPrint(
        '[windowing_demo] Aserción conocida suprimida al cerrar el '
        'diálogo-ventana (docs/showdialog-macos.md): '
        '${texto.split('\n').first}',
      );
      return;
    }
    previo?.call(detalles);
  };
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
  void onWindowCloseRequested(RegularWindowController controller) {
    destruirSeguro(controller); // Diferido; no llamar a super (destruiría ya).
  }

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
  void onWindowCloseRequested(DialogWindowController controller) {
    destruirSeguro(controller); // Diferido; no llamar a super (destruiría ya).
  }

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

  WindowEntry? _popup;
  _FaseEmergente _fasePopup = _FaseEmergente.cerrado;
  WindowEntry? _tooltip;
  _FaseEmergente _faseTooltip = _FaseEmergente.cerrado;
  Completer<void>? _popupDestruido;
  Completer<void>? _tooltipDestruido;
  int _secuenciaRegulares = 0;

  /// Rectángulo global (en coordenadas de esta ventana) del widget con [key].
  Rect _rectDe(GlobalKey key) {
    final RenderBox caja = key.currentContext!.findRenderObject()! as RenderBox;
    return caja.localToGlobal(Offset.zero) & caja.size;
  }

  // --------------------------- Ventana regular ----------------------------

  Future<void> _crearVentanaRegular() async {
    // La ventana nueva toma el foco: cerrar emergentes primero evita el
    // aborto de enumeración del embedder (docs/popups-macos.md).
    await _cerrarEmergentes();
    if (!mounted) {
      return;
    }
    final WindowRegistry registro = WindowRegistry.of(context);
    final int numero = ++_secuenciaRegulares;

    late final WindowEntry entrada;
    final RegularWindowController controlador = RegularWindowController(
      size: const Size(480, 380),
      title: 'Ventana regular #$numero',
      delegate: _AlDestruirRegular(() {
        _destruccionSolicitada.remove(entrada.controller);
        registro.unregister(entrada);
      }),
    );
    entrada = WindowEntry(
      controller: controlador,
      builder: (_) => ContenidoVentanaRegular(numero: numero),
    );
    registro.register(entrada);
  }

  // -------------------------------- Popup ---------------------------------

  void _alternarPopup() {
    switch (_fasePopup) {
      case _FaseEmergente.abriendo:
      case _FaseEmergente.cerrando:
        return; // Transición en curso: ignorar el clic.
      case _FaseEmergente.abierto:
        setState(() => _fasePopup = _FaseEmergente.cerrando);
        destruirSeguro(_popup!.controller); // El delegate limpia el estado.
        return;
      case _FaseEmergente.cerrado:
        break;
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
        _destruccionSolicitada.remove(entrada.controller);
        registro.unregister(entrada);
        if (mounted) {
          setState(() {
            _popup = null;
            _fasePopup = _FaseEmergente.cerrado;
          });
        }
        final Completer<void>? avisado = _popupDestruido;
        _popupDestruido = null;
        if (avisado != null && !avisado.isCompleted) {
          avisado.complete();
        }
      }),
    );
    entrada = WindowEntry(
      controller: controlador,
      builder: (_) => const _ContenidoPopup(),
    );
    registro.register(entrada);
    setState(() {
      _popup = entrada;
      _fasePopup = _FaseEmergente.abriendo;
    });
    _marcarAbiertoTrasAsentarse(entrada, esPopup: true);
  }

  // ------------------------------- Tooltip --------------------------------

  void _alternarTooltip() {
    switch (_faseTooltip) {
      case _FaseEmergente.abriendo:
      case _FaseEmergente.cerrando:
        return; // Transición en curso: ignorar el clic.
      case _FaseEmergente.abierto:
        setState(() => _faseTooltip = _FaseEmergente.cerrando);
        destruirSeguro(_tooltip!.controller);
        return;
      case _FaseEmergente.cerrado:
        break;
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
        _destruccionSolicitada.remove(entrada.controller);
        registro.unregister(entrada);
        if (mounted) {
          setState(() {
            _tooltip = null;
            _faseTooltip = _FaseEmergente.cerrado;
          });
        }
        final Completer<void>? avisado = _tooltipDestruido;
        _tooltipDestruido = null;
        if (avisado != null && !avisado.isCompleted) {
          avisado.complete();
        }
      }),
    );
    entrada = WindowEntry(
      controller: controlador,
      builder: (_) => const _ContenidoTooltip(),
    );
    registro.register(entrada);
    setState(() {
      _tooltip = entrada;
      _faseTooltip = _FaseEmergente.abriendo;
    });
    _marcarAbiertoTrasAsentarse(entrada, esPopup: false);
  }

  /// Pasa la emergente de `abriendo` a `abierto` cuando su redimensionado
  /// inicial (sized-to-content) ya se asentó: un frame más un margen corto.
  /// Mientras tanto el botón queda deshabilitado y no se permite destruir.
  void _marcarAbiertoTrasAsentarse(WindowEntry entrada,
      {required bool esPopup}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Future<void>.delayed(const Duration(milliseconds: 250), () {
        if (!mounted) {
          return;
        }
        setState(() {
          if (esPopup &&
              identical(_popup, entrada) &&
              _fasePopup == _FaseEmergente.abriendo) {
            _fasePopup = _FaseEmergente.abierto;
          } else if (!esPopup &&
              identical(_tooltip, entrada) &&
              _faseTooltip == _FaseEmergente.abriendo) {
            _faseTooltip = _FaseEmergente.abierto;
          }
        });
      });
    });
  }

  /// Espera a que ninguna emergente siga en fase `abriendo`.
  Future<void> _esperarAsentamiento() async {
    int intentos = 0;
    while ((_fasePopup == _FaseEmergente.abriendo ||
            _faseTooltip == _FaseEmergente.abriendo) &&
        intentos < 40) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      intentos += 1;
    }
  }

  /// Cierra popup y tooltip (si los hay) y espera su destrucción confirmada.
  /// En el canal main, si la principal deja de ser key window (p. ej. al
  /// abrirse un diálogo/sheet o cualquier ventana nueva) con emergentes
  /// abiertas, el embedder enumera y muta a la vez su lista de ventanas y
  /// AppKit aborta ("Collection was mutated while being enumerated");
  /// ver docs/popups-macos.md.
  Future<void> _cerrarEmergentes() async {
    await _esperarAsentamiento();
    final List<Future<void>> pendientes = <Future<void>>[];
    if (_popup != null) {
      _popupDestruido ??= Completer<void>();
      pendientes.add(_popupDestruido!.future);
      if (_fasePopup == _FaseEmergente.abierto) {
        setState(() => _fasePopup = _FaseEmergente.cerrando);
        destruirSeguro(_popup!.controller);
      }
    }
    if (_tooltip != null) {
      _tooltipDestruido ??= Completer<void>();
      pendientes.add(_tooltipDestruido!.future);
      if (_faseTooltip == _FaseEmergente.abierto) {
        setState(() => _faseTooltip = _FaseEmergente.cerrando);
        destruirSeguro(_tooltip!.controller);
      }
    }
    if (pendientes.isEmpty) {
      return;
    }
    await Future.wait(pendientes)
        .timeout(const Duration(seconds: 2), onTimeout: () => <void>[]);
    // Margen para que AppKit estabilice la ventana clave antes de crear otra.
    await Future<void>.delayed(const Duration(milliseconds: 80));
  }

  // ------------------------------- Diálogos -------------------------------

  Future<void> _crearDialogo({required bool modal}) async {
    // El diálogo (sheet si es modal) roba el foco a la principal; con
    // emergentes abiertas eso aborta en el embedder. Cerrarlas antes.
    await _cerrarEmergentes();
    if (!mounted) {
      return;
    }
    final WindowRegistry registro = WindowRegistry.of(context);

    late final WindowEntry entrada;
    final DialogWindowController controlador = DialogWindowController(
      size: const Size(400, 260),
      title: modal ? 'Diálogo modal' : 'Diálogo sin padre (modeless)',
      // Con parent, la plataforma lo trata como modal de esa ventana.
      parent: modal ? WindowScope.of(context) : null,
      delegate: _AlDestruirDialogo(() {
        _destruccionSolicitada.remove(entrada.controller);
        registro.unregister(entrada);
      }),
    );
    entrada = WindowEntry(
      controller: controlador,
      builder: (_) => _ContenidoDialogo(modal: modal),
    );
    registro.register(entrada);
  }

  Future<void> _mostrarShowDialog({bool fullscreen = false}) async {
    await _cerrarEmergentes();
    if (!mounted) {
      return;
    }
    final NavigatorState navegador = Navigator.of(context);
    // Con windowing activo, showDialog crea una ventana nativa hija. Con
    // fullscreen usa tamaño fijo (funciona hoy en macOS); sin él usa
    // sized-to-content, que hoy produce un sheet fantasma que bloquea la
    // app. Rescate en dos capas (docs/showdialog-macos.md): la sonda de
    // abajo mide el tamaño real de la ventana anfitriona, y el vigilante
    // nativo del AppDelegate termina el sheet aunque Dart quede congelado.
    await showDialog<void>(
      context: context,
      fullscreenDialog: fullscreen,
      builder: (BuildContext context) => _SondaVentanaDialogo(
        alDetectarFantasma: () {
          if (navegador.mounted && navegador.canPop()) {
            navegador.pop();
          }
          if (mounted) {
            ScaffoldMessenger.of(this.context).showSnackBar(
              const SnackBar(
                content: Text(
                  'showDialog creó un sheet sin tamaño (bug de macOS en el '
                  'canal main); se canceló automáticamente.',
                ),
              ),
            );
          }
        },
        child: AlertDialog(
          title: const Text('showDialog de Material'),
          content: const Text(
            'Este diálogo usa el showDialog de siempre.\n\n'
            'Con la bandera enable-windowing, Flutter lo renderiza en una '
            'ventana nativa hija en lugar de una ruta superpuesta.',
          ),
          actions: <Widget>[
            _BotonCerrarTrasAsentar(
              alCerrar: () => Navigator.of(context).pop(),
            ),
          ],
        ),
      ),
    );
  }

  void _mostrarDialogoRutaClasica() {
    // Empuja DialogRoute directamente: esquiva la rama de windowing de
    // showRawDialog y muestra el diálogo clásico dentro de esta ventana.
    Navigator.of(context).push(
      DialogRoute<void>(
        context: context,
        builder: (BuildContext context) => AlertDialog(
          title: const Text('Diálogo clásico (misma ventana)'),
          content: const Text(
            'DialogRoute empujada a mano: sin ventana nativa, con barrera '
            'superpuesta, como en el canal stable.',
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cerrar'),
            ),
          ],
        ),
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
                    label: Text(switch (_fasePopup) {
                      _FaseEmergente.cerrado => 'Mostrar popup',
                      _FaseEmergente.abriendo => 'Abriendo popup…',
                      _FaseEmergente.abierto => 'Ocultar popup',
                      _FaseEmergente.cerrando => 'Cerrando popup…',
                    }),
                    onPressed: _fasePopup == _FaseEmergente.cerrado ||
                            _fasePopup == _FaseEmergente.abierto
                        ? _alternarPopup
                        : null,
                  ),
                  const SizedBox(height: 8),
                  FilledButton.tonalIcon(
                    key: _botonTooltip,
                    icon: const Icon(Icons.info_outline),
                    label: Text(switch (_faseTooltip) {
                      _FaseEmergente.cerrado => 'Mostrar tooltip',
                      _FaseEmergente.abriendo => 'Abriendo tooltip…',
                      _FaseEmergente.abierto => 'Ocultar tooltip',
                      _FaseEmergente.cerrando => 'Cerrando tooltip…',
                    }),
                    onPressed: _faseTooltip == _FaseEmergente.cerrado ||
                            _faseTooltip == _FaseEmergente.abierto
                        ? _alternarTooltip
                        : null,
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
                    label: const Text(
                        'showDialog (ventana sized-to-content · bug)'),
                    onPressed: _mostrarShowDialog,
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    icon: const Icon(Icons.open_in_full),
                    label: const Text(
                        'showDialog fullscreen (ventana, tamaño fijo)'),
                    onPressed: () => _mostrarShowDialog(fullscreen: true),
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    icon: const Icon(Icons.chat_bubble),
                    label: const Text('showDialog clásico (misma ventana)'),
                    onPressed: _mostrarDialogoRutaClasica,
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
                              onPressed: () => destruirSeguro(e.controller),
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
                onPressed: () => destruirSeguro(ventana),
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
                    onPressed: () => destruirSeguro(WindowScope.of(context)),
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
                  onPressed: () => destruirSeguro(WindowScope.of(context)),
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

/// Sonda dentro del contenido del diálogo: si a los 5 s la ventana que lo
/// aloja sigue sin tamaño (sheet fantasma de sized-to-content), dispara el
/// rescate. Si Dart quedó congelado por la sesión modal del sheet, primero
/// actúa el vigilante nativo del AppDelegate y esta sonda remata la ruta al
/// reanudarse el isolate.
class _SondaVentanaDialogo extends StatefulWidget {
  const _SondaVentanaDialogo({
    required this.alDetectarFantasma,
    required this.child,
  });

  final VoidCallback alDetectarFantasma;
  final Widget child;

  @override
  State<_SondaVentanaDialogo> createState() => _SondaVentanaDialogoState();
}

class _SondaVentanaDialogoState extends State<_SondaVentanaDialogo> {
  Timer? _vigilante;

  @override
  void initState() {
    super.initState();
    _vigilante = Timer(const Duration(seconds: 5), () {
      if (!mounted) {
        return;
      }
      final Size? tamano = WindowScope.maybeContentSizeOf(context);
      if (tamano == null || tamano.isEmpty) {
        widget.alDetectarFantasma();
      }
    });
  }

  @override
  void dispose() {
    _vigilante?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Botón "Cerrar" que se habilita ~600 ms después de montarse. Al abrirse,
/// la ventana del diálogo (sheet) programa commits diferidos de
/// presentación/redimensionado; como `_DialogWindowRoute.didPop` la destruye
/// de forma síncrona, cerrarla con un commit pendiente dispara la misma
/// carrera FFI del engine documentada para popups (docs/popups-macos.md).
/// Este pequeño asentamiento reduce esa ventana de carrera.
class _BotonCerrarTrasAsentar extends StatefulWidget {
  const _BotonCerrarTrasAsentar({required this.alCerrar});

  final VoidCallback alCerrar;

  @override
  State<_BotonCerrarTrasAsentar> createState() =>
      _BotonCerrarTrasAsentarState();
}

class _BotonCerrarTrasAsentarState extends State<_BotonCerrarTrasAsentar> {
  Timer? _temporizador;
  bool _listo = false;
  bool _cerrando = false;

  @override
  void initState() {
    super.initState();
    _temporizador = Timer(const Duration(milliseconds: 600), () {
      if (mounted) {
        setState(() => _listo = true);
      }
    });
  }

  @override
  void dispose() {
    _temporizador?.cancel();
    super.dispose();
  }

  /// El pop destruye la ventana de forma síncrona (didPop); diferirlo deja
  /// drenar el commit encolado por el repintado de este mismo clic.
  Future<void> _cerrarDiferido() async {
    setState(() => _cerrando = true);
    await Future<void>.delayed(_demoraDestruccion);
    if (mounted) {
      widget.alCerrar();
    }
  }

  @override
  Widget build(BuildContext context) {
    final bool habilitado = _listo && !_cerrando;
    return TextButton(
      onPressed: habilitado ? _cerrarDiferido : null,
      child: Text(_cerrando ? 'Cerrando…' : 'Cerrar'),
    );
  }
}
