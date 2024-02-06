// ignore_for_file: deprecated_member_use, camel_case_types

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:optimize_battery/optimize_battery.dart';
import 'package:location/location.dart' as locate_dart;
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:web_socket_channel/status.dart' as status;

InAppWebViewController main_control = null as InAppWebViewController;
String access_token = "";
WebSocketChannel channel = null as WebSocketChannel;
locate_dart.LocationData current_position = null as locate_dart.LocationData;
HttpClient client = HttpClient();
bool auto_reconnect = false;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await LocationPermissionsHandler().request();
  await OptimizeBattery.stopOptimizingBatteryUsage();

  Meecha_App app = const Meecha_App();

  locate_dart.Location location = locate_dart.Location();
  await location.enableBackgroundMode(enable: true);

  location.onLocationChanged.listen((locate_dart.LocationData currentpos) {
    debugPrint("${currentpos.latitude}, ${currentpos.longitude}");
    //JSのイベントを呼び出す
    try {
      main_control.evaluateJavascript(source: """
        call_event(${currentpos.latitude}, ${currentpos.longitude});
      """);
    } catch (ex) {
      debugPrint(ex.toString());
    }
    current_position = currentpos;
  });

  client.badCertificateCallback = (cert, host, port) => true;

  runApp(app);
}

enum LocationPermissionStatus { granted, denied, permanentlyDenied, restricted }

class LocationPermissionsHandler {
  Future<bool> get isGranted async {
    final status = await Permission.location.status;
    switch (status) {
      case PermissionStatus.granted:
      case PermissionStatus.limited:
        return true;
      case PermissionStatus.denied:
      case PermissionStatus.permanentlyDenied:
      case PermissionStatus.restricted:
        return false;
      default:
        return false;
    }
  }

  Future<bool> get isAlwaysGranted {
    return Permission.locationAlways.isGranted;
  }

  Future<LocationPermissionStatus> request() async {
    final status = await Permission.location.request();
    switch (status) {
      case PermissionStatus.granted:
        return LocationPermissionStatus.granted;
      case PermissionStatus.denied:
        return LocationPermissionStatus.denied;
      case PermissionStatus.limited:
      case PermissionStatus.permanentlyDenied:
        return LocationPermissionStatus.permanentlyDenied;
      case PermissionStatus.restricted:
        return LocationPermissionStatus.restricted;
      default:
        return LocationPermissionStatus.denied;
    }
  }
}

class Meecha_App extends StatelessWidget {
  const Meecha_App({super.key});

  // This widget is the root of your application.
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Meecha',
      theme: ThemeData(
        // This is the theme of your application.
        //
        // TRY THIS: Try running your application with "flutter run". You'll see
        // the application has a purple toolbar. Then, without quitting the app,
        // try changing the seedColor in the colorScheme below to Colors.green
        // and then invoke "hot reload" (save your changes or press the "hot
        // reload" button in a Flutter-supported IDE, or press "r" if you used
        // the command line to start the app).
        //
        // Notice that the counter didn't reset back to zero; the application
        // state is not lost during the reload. To reset the state, use hot
        // restart instead.
        //
        // This works for code too, not just values: Most code changes can be
        // tested with just a hot reload.
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),
      home: const Meecha_Page(title: 'Meecha'),
    );
  }
}

class Meecha_Page extends StatefulWidget {
  const Meecha_Page({super.key, required this.title});

  // This widget is the home page of your application. It is stateful, meaning
  // that it has a State object (defined below) that contains fields that affect
  // how it looks.

  // This class is the configuration for the state. It holds the values (in this
  // case the title) provided by the parent (in this case the App widget) and
  // used by the build method of the State. Fields in a Widget subclass are
  // always marked "final".

  final String title;

  @override
  State<Meecha_Page> createState() => Meecha_Page_State();
}

class Meecha_Page_State extends State<Meecha_Page> {
  @override
  void initState() {
    super.initState();
  }

  @override
  void dispose() {
    super.dispose();
    channel.sink.close(status.goingAway);
  }

  void init_web(List<dynamic> args) {
    dynamic decode_data = jsonDecode(args[0] as String);

    String token = decode_data["token"];
    String wsurl = decode_data["wsurl"];

    auto_reconnect = true;
    connect(wsurl, token);
  }

  // WebSocket 切断
  void stop_ws(List<dynamic> args) {
    try {
      channel.sink.close(1000);
    } catch (ex) {
      debugPrint(ex.toString());
    }
  }

  void connect(String wsurl, String atoken) {
    try {
      channel.sink.close(1000);
    } catch (ex) {
      debugPrint(ex.toString());
    }

    channel = IOWebSocketChannel.connect(Uri.parse(wsurl),
        customClient: client, connectTimeout: const Duration(seconds: 1));
    channel.stream.listen((msg) {
      dynamic data = jsonDecode(msg);

      switch (data["Command"]) {
        case "Location_Token":
          access_token = data["Payload"];
          channel.sink.add(jsonEncode({
            "Command": "location",
            "Payload": {
              "token": access_token,
              "lat": current_position.latitude,
              "lng": current_position.longitude
            }
          }));
          break;
        default:
          try {
            main_control.evaluateJavascript(source: """
              on_recved(${jsonEncode(data)});
            """);
          } catch (ex) {
            debugPrint(ex.toString());
          }
          break;
      }
    }, onError: (error) {
      debugPrint("エラーです:${error}");
    }, onDone: () {
      debugPrint("通信を切断されました");
      debugPrint(channel.closeCode.toString());
      //再接続がオフの場合戻る
      if (!auto_reconnect) {
        return;
      }

      //切断コードが1005のとき
      if (channel.closeCode.toString() != "1000") {
        Future.delayed(Duration(seconds: 5)).then((_) {
          debugPrint('再接続');
          try {
            connect(wsurl, atoken);
          } catch (ex) {
            debugPrint(ex.toString());
          }
        });
      }
      ;
    });

    channel.sink.add(jsonEncode({"Command": "auth", "Payload": atoken}));
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        SafeArea(
            child: InAppWebView(
                initialUrlRequest: URLRequest(
                    url: WebUri(
                        "https://wao2server.tail6cf7b.ts.net/static/meecha/")),
                androidOnGeolocationPermissionsShowPrompt:
                    (InAppWebViewController controller, String origin) async {
                  return GeolocationPermissionShowPromptResponse(
                      origin: origin, allow: true, retain: true);
                },
                onReceivedServerTrustAuthRequest:
                    (controller, challenge) async {
                  return ServerTrustAuthResponse(
                      action: ServerTrustAuthResponseAction.PROCEED);
                },
                initialOptions: InAppWebViewGroupOptions(
                  android: AndroidInAppWebViewOptions(
                    useWideViewPort: true,
                    geolocationEnabled: true,
                  ),
                  ios: IOSInAppWebViewOptions(
                    allowsInlineMediaPlayback: true,
                  ),
                ),
                onLoadStop: (controller, url) async {
                  main_control = controller;
                },
                onLoadStart: (controller, url) async {
                  auto_reconnect = false;
                  try {
                    stop_ws([""]);
                  } catch (ex) {
                    debugPrint(ex.toString());
                  }
                  controller.addJavaScriptHandler(
                    handlerName: 'web_inited',
                    callback: init_web,
                  );

                  controller.addJavaScriptHandler(
                    handlerName: 'stop_ws',
                    callback: stop_ws,
                  );
                },
                androidOnPermissionRequest: (InAppWebViewController controller,
                    String origin, List<String> resources) async {
                  return PermissionRequestResponse(
                      resources: resources,
                      action: PermissionRequestResponseAction.GRANT);
                })),
      ],
    );
  }
}
