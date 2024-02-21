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
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

InAppWebViewController main_control = null as InAppWebViewController;
String access_token = "";
WebSocketChannel channel = null as WebSocketChannel;
locate_dart.LocationData current_position = null as locate_dart.LocationData;
HttpClient client = HttpClient();
bool auto_reconnect = false;
locate_dart.Location location = locate_dart.Location();
bool connecting = false;

final FlutterLocalNotificationsPlugin notificationsPlugin =
    FlutterLocalNotificationsPlugin();
const notificationDetails = NotificationDetails(
    android: AndroidNotificationDetails(
  '0eba0d7b-fd6a-4775-bdf7-79a82968c692',
  'Meecha Notification',
));

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await LocationPermissionsHandler().request();
  await OptimizeBattery.stopOptimizingBatteryUsage();

  Meecha_App app = const Meecha_App();

  await location.enableBackgroundMode(enable: true);
  await location.changeNotificationOptions(
      iconName: "ic_launcher",
      channelName: "Meecha_Core_Notify",
      title: "Meecha",
      subtitle: "Meecha は位置情報を使用しています",
      onTapBringToFront: true);

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

  try {
    const initializationSettings = InitializationSettings(
      android: AndroidInitializationSettings('ic_launcher'),
    );

    if (Platform.isAndroid) {
      await notificationsPlugin
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>()
          ?.requestNotificationsPermission();
    }

    await notificationsPlugin.initialize(
      initializationSettings,

      // 通知をタップしたときの処理(今回はprint)
      onDidReceiveNotificationResponse:
          (NotificationResponse notificationResponse) async {
        debugPrint('id=${notificationResponse.id}の通知に対してアクション。');
      },
    );
  } catch (ex) {
    debugPrint(ex.toString());
  }

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
  double load_val = 0;
  bool showErrorPage = false;
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

  void connect(String wsurl, String atoken) async {
    connecting = true;
    try {
      channel.sink.close(1000);
    } catch (ex) {
      debugPrint(ex.toString());
    }

    Future.delayed(Duration(seconds: 5)).then((_) {
      connecting = false;

      try {
        location
            .changeNotificationOptions(
                iconName: "ic_launcher",
                channelName: "Meecha_Core_Notify",
                title: "Meecha",
                subtitle: "接続を開始しました",
                onTapBringToFront: true)
            .then((value) => null);
      } catch (ex) {
        debugPrint(ex.toString());
      }

      channel = IOWebSocketChannel.connect(Uri.parse(wsurl),
          customClient: client, connectTimeout: Duration(seconds: 5));

      channel.stream.listen((msg) {
        bool call_js = false;

        dynamic data = jsonDecode(msg);

        switch (data["Command"]) {
          case "Auth_Complete":
            try {
              location
                  .changeNotificationOptions(
                      iconName: "ic_launcher",
                      channelName: "Meecha_Core_Notify",
                      title: "Meecha",
                      subtitle: "接続完了",
                      onTapBringToFront: true)
                  .then((value) => null);

              notificationsPlugin.cancel(10000);
            } catch (ex) {
              debugPrint(ex.toString());
            }
            break;
          case "stop_notify":
            try {
              dynamic payload_data = data["Payload"];

              notificationsPlugin
                  .cancel(payload_data["userid"].hashCode)
                  .then((value) => null);

              call_js = true;
              break;
            } catch (ex) {
              debugPrint(ex.toString());
            }
            break;
          case "near_friend":
            try {
              dynamic payload_data = data["Payload"];

              if (payload_data["is_first"] && payload_data["is_self"]) {
                try {
                  notificationsPlugin
                      .show(
                          payload_data["userid"].hashCode,
                          "Meecha",
                          "${payload_data["unane"]}さんが近くにいます",
                          notificationDetails)
                      .then((value) => null);
                } catch (ex) {
                  debugPrint(ex.toString());
                }
              }
              ;

              call_js = true;
              break;
            } catch (ex) {
              debugPrint(ex.toString());
            }
            break;
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
            call_js = true;
            break;
        }

        if (call_js) {
          try {
            main_control.evaluateJavascript(source: """
              on_recved(${jsonEncode(data)});
            """);
          } catch (ex) {
            debugPrint(ex.toString());
          }
        }
      }, onError: (error) {
        debugPrint("エラーです:${error}");
      }, onDone: () async {
        debugPrint("通信を切断されました");
        try {
          location
              .changeNotificationOptions(
                  iconName: "ic_launcher",
                  channelName: "Meecha_Core_Notify",
                  title: "Meecha",
                  subtitle: "切断されました",
                  onTapBringToFront: true)
              .then((value) => null);
        } catch (ex) {
          debugPrint(ex.toString());
        }

        debugPrint(channel.closeCode.toString());
        //再接続がオフの場合戻る
        if (!auto_reconnect) {
          return;
        }

        //接続中の場合戻る
        if (connecting) {
          return;
        }

        //切断コードが1005のとき
        if (channel.closeCode.toString() != "1000") {
          try {
            notificationsPlugin
                .show(10000, "Meecha", "切断されました", notificationDetails)
                .then((value) => null);
          } catch (ex) {
            debugPrint(ex.toString());
          }
          debugPrint('再接続');
          try {
            connect(wsurl, atoken);
          } catch (ex) {
            debugPrint(ex.toString());
          }
        }
        ;
      });

      channel.sink.add(jsonEncode({"Command": "auth", "Payload": atoken}));
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
        resizeToAvoidBottomInset: false,
        body: WillPopScope(
            child: SafeArea(
                bottom: false,
                left: false,
                right: false,
                child: Stack(
              children: [
                InAppWebView(
                    initialUrlRequest: URLRequest(
                        url: WebUri(
                            "https://wao2server.tail6cf7b.ts.net/static/meecha/")),
                    androidOnGeolocationPermissionsShowPrompt:
                        (InAppWebViewController controller,
                            String origin) async {
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
                    onLoadError: (controller, url, code, message) => {
                      setState(() => showErrorPage = true,)
                    },
                    onLoadHttpError: (controller, url, statusCode, description) => {
                      setState(() => showErrorPage = true,)
                    },
                    onLoadStop: (controller, url) async {
                      main_control = controller;
                    },
                    onLoadStart: (controller, url) async {
                      setState(() => showErrorPage = false,);
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
                    onProgressChanged: (controller, progress) {
                      try {
                        setState(() {
                          load_val = progress / 100;
                        });
                      } catch (ex) {
                        debugPrint(ex.toString());
                      }
                    },
                    androidOnPermissionRequest:
                        (InAppWebViewController controller, String origin,
                            List<String> resources) async {
                      return PermissionRequestResponse(
                          resources: resources,
                          action: PermissionRequestResponseAction.GRANT);
                    }),
                    
                showErrorPage ? Center(
                  child: Container(
                    color: Colors.white,
                    alignment: Alignment.center,
                    height: double.infinity,
                    width: double.infinity,
                    child: Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                      Text('読み込みに失敗しました'),
                      ElevatedButton(onPressed: () async {
                        try {
                          main_control.goBack();
                        } catch (ex) {
                          debugPrint(ex.toString());
                        }
                      }, child: Text('戻る'))
                    ])) 
                  ),
                ) : SizedBox(height: 0, width: 0),
                LinearProgressIndicator(
                  valueColor: new AlwaysStoppedAnimation<Color>(Colors.lightBlueAccent),
                  value:load_val,
                ),
              ],
            )),
            onWillPop: () async {
              try {
                await main_control.goBack();
              } catch (ex) {
                debugPrint(ex.toString());
              }
              return false;
            }));
  }
}
