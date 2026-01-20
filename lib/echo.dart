import 'dart:async';
import 'dart:convert';
import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;

import 'package:web_socket_channel/web_socket_channel.dart';

/// Represents a WebSocket channel with event listeners
class EchoChannel {
  /// The underlying WebSocket channel connection
  final WebSocketManager wsManager;

  final String channelName;

  final Echo? echoInstance;

  /// Whether this is a private channel (requires authentication)
  final bool isPrivate;

  /// Map of event names to their callback functions
  final Map<String, Function(dynamic)> listeners = {};

  PrivateChannelAuthenticator? _authenticator;
  final EchoConfig config;

  EchoChannel({
    required this.wsManager,
    required this.config,
    required this.channelName,
    this.echoInstance,
    this.isPrivate = false,
    Map<String, Function(dynamic p1)>? listeners,
  }) {
    if (isPrivate) {
      _authenticator = PrivateChannelAuthenticator(
        config,
        wsManager,
        echoInstance,
      );
    }
    if (listeners != null) {
      listeners.forEach((k, v) {
        this.listeners[k] = v;
      });
    }
  }

  /// Register a callback function for a specific event on this channel
  void listen(String event, Function(dynamic) callback) {
    listeners[event] = callback;
  }

  /// Clear channel listeners (DON'T close WebSocket connection)
  void close() {
    listeners.clear();
  }

  /// Authenticate and subscribe for private channel
  Future<void> authenticateAndSubscribe(String channelName) async {
    if (isPrivate && _authenticator != null) {
      await _authenticator!.authenticateAndSubscribe(channelName);
    }
  }
}

/// Configuration class for Echo WebSocket connection
class EchoConfig {
  final String key;
  final String wsHost;
  final String host;
  final String scheme;
  final String sanctumToken;
  final int wsPort;
  final int wssPort;
  final String authUrl;
  final bool keepAlive = true;

  EchoConfig({
    required this.key,
    required this.wsHost,
    required this.host,
    required this.scheme,
    required this.sanctumToken,
    this.wsPort = 80,
    this.wssPort = 443,
    this.authUrl = '/broadcasting/auth',
  });

  /// Get the WebSocket URL based on configuration
  String getWebSocketUrl() {
    final port = scheme == 'https' ? wssPort : wsPort;
    final wsScheme = scheme == 'https' ? 'wss' : 'ws';
    return '$wsScheme://$wsHost:$port/app/$key';
  }

  /// Get the authentication URL
  String getAuthUrl() => '$scheme://$host$authUrl';
}

/// Handles WebSocket connection and message processing
class WebSocketManager {
  final EchoConfig config;
  WebSocketChannel? _channel;
  String? _socketId;
  Timer? _pingTimer;

  WebSocketManager(this.config);

  /// Get the current WebSocket channel
  WebSocketChannel? get channel => _channel;

  /// Get the current socket ID
  String? get socketId => _socketId;

  /// Establish WebSocket connection
  Future<WebSocketChannel> connect({force = false}) async {
    if (_channel != null && !force) return _channel!;

    final wsUrl = config.getWebSocketUrl();
    debugPrint('[Echo] Connecting to WebSocket: $wsUrl');

    try {
      _channel = WebSocketChannel.connect(Uri.parse(wsUrl));

      // Wait a bit for connection to establish
      await Future.delayed(const Duration(milliseconds: 500));

      _startPingTimer();
      debugPrint('[Echo] WebSocket connected successfully');
      return _channel!;
    } catch (e) {
      debugPrint('[Echo] WebSocket connection failed: $e');
      _channel = null;
      rethrow;
    }
  }

  /// Start periodic ping to keep connection alive
  void _startPingTimer() {
    _pingTimer?.cancel();
    _pingTimer = Timer.periodic(const Duration(seconds: 30), (timer) {
      if (_channel != null) {
        try {
          _channel?.sink.add(jsonEncode({"event": "pusher:ping", "data": {}}));
        } catch (e) {
          debugPrint('[Echo] Ping failed: $e');
          timer.cancel();
        }
      }
    });
  }

  /// Close the WebSocket connection
  void disconnect() {
    _pingTimer?.cancel();
    try {
      _channel?.sink.close();
    } catch (e) {
      debugPrint('[Echo] Error closing WebSocket: $e');
    }
    _channel = null;
    _socketId = null;
  }

  /// Set the socket ID from connection establishment
  void setSocketId(String socketId) {
    _socketId = socketId;
  }
}

/// Handles private channel authentication
class PrivateChannelAuthenticator {
  String? authToken;
  final EchoConfig config;
  WebSocketManager wsManager;
  final Echo? echoInstance;

  PrivateChannelAuthenticator(this.config, this.wsManager, [this.echoInstance]);

  void setWsManager(WebSocketManager wsManager) {
    this.wsManager = wsManager;
  }

  Future<void> waitForSocketId() async {
    int attempt = 0;
    while (wsManager.socketId == null && attempt < 50) {
      await Future.delayed(const Duration(milliseconds: 100));
      attempt++;
    }
    if (wsManager.socketId == null) {
      throw Exception("[Echo] Socket ID not available");
    }
  }

  /// Authenticate and subscribe to a private channel
  Future<void> authenticateAndSubscribe(String channelName) async {
    await waitForSocketId();
    if (wsManager.socketId == null) {
      throw Exception(
        '[Echo] Socket ID not available. Connection not established.',
      );
    }

    final authData = {
      'socket_id': wsManager.socketId,
      'channel_name': 'private-$channelName',
    };

    try {
      debugPrint('[Echo] Authenticating channel: private-$channelName');
      debugPrint('[Echo] Auth URL: ${config.getAuthUrl()}');
      debugPrint('[Echo] Socket ID: ${wsManager.socketId}');

      if (authToken != null) {
        _subscribeToPrivateChannel(channelName, authToken!);
        debugPrint(
          '[Echo] Authentication successful for channel: private-$channelName',
        );
        return;
      }

      final response = await http
          .post(
            Uri.parse(config.getAuthUrl()),
            headers: {
              'Authorization': 'Bearer ${config.sanctumToken}',
              'Content-Type': 'application/json',
              'Accept': 'application/json',
              'User-Agent': 'HodrivApp/1.0',
            },
            body: jsonEncode(authData),
          )
          .timeout(const Duration(seconds: 10));

      debugPrint('[Echo] Auth response status: ${response.statusCode}');

      if (response.statusCode == 200) {
        final auth = jsonDecode(response.body);
        authToken = auth['auth'];
        _subscribeToPrivateChannel(channelName, authToken!);
        debugPrint(
          '[Echo] Authentication successful for channel: private-$channelName',
        );
      } else {
        throw Exception(
          '[Echo] Authentication failed: ${response.statusCode} - ${response.body}',
        );
      }
    } catch (e) {
      debugPrint('[Echo] Authentication error details: $e');
      if (e is http.ClientException) {
        throw Exception(
          '[Echo] Network error during authentication: ${e.message}',
        );
      }
      throw Exception('[Echo] Authentication error: $e');
    }
  }

  /// Subscribe to private channel after authentication
  void _subscribeToPrivateChannel(String channelName, String auth) {
    if (wsManager.channel == null) {
      debugPrint('[Echo] Cannot subscribe: WebSocket channel is null');
      echoInstance?.addFailedPrivateChannel(channelName);
      return;
    }

    final subscription = {
      'event': 'pusher:subscribe',
      'data': {'auth': auth, 'channel': 'private-$channelName'},
    };

    try {
      wsManager.channel?.sink.add(jsonEncode(subscription));
      debugPrint('[Echo] Subscription sent for channel: private-$channelName');
      echoInstance?.removeFailedPrivateChannel(channelName);
    } catch (e) {
      debugPrint('[Echo] Error sending subscription: $e');
      echoInstance?.addFailedPrivateChannel(channelName);
    }
  }

  void clearAuthToken() {
    authToken = null;
  }
}

/// Handles message parsing and event routing
class MessageHandler {
  /// Parse incoming WebSocket message
  static dynamic parseMessage(dynamic data) {
    final response = jsonDecode(data);

    try {
      return response['data'] is String && response['data'].isNotEmpty
          ? jsonDecode(response['data'])
          : response['data'];
    } catch (e) {
      return response['data'];
    }
  }

  /// Check if message is a connection establishment event
  static bool isConnectionEstablished(dynamic response) {
    return response['event'] == 'pusher:connection_established';
  }

  /// Check if event matches a listener pattern
  static bool eventMatchesListener(String event, String listenerKey) {
    // Pattern 1: listener starts with dot, match without dot
    final pattern1 =
        listenerKey.startsWith('.') && listenerKey.substring(1) == event;
    // Pattern 2: full Laravel event class name
    final pattern2 = event == 'App\\Events\\$listenerKey';
    // Pattern 3: direct match
    final pattern3 = event == listenerKey;

    return pattern1 || pattern2 || pattern3;
  }
}

enum ChannelState { disconnected, connecting, connected }

/// Main Echo class for managing WebSocket connections and channels
/// Handles connection to Pusher-compatible WebSocket servers
class Echo {
  final EchoConfig _config;
  late WebSocketManager _wsManager;
  PrivateChannelAuthenticator? _authenticator;

  final Map<String, EchoChannel> _channels = {};
  final Map<String, bool> _channelConnected = {};
  final Map<String, ChannelState> _channelStates = {};
  bool _isStreamListened = false;
  Completer<void>? _connectionCompleter;

  // Tambahan: daftar channel private yang gagal subscribe
  final List<String> _failedPrivateChannels = [];
  List<String> get failedPrivateChannels => _failedPrivateChannels;

  void addFailedPrivateChannel(String channelName) {
    if (!_failedPrivateChannels.contains(channelName)) {
      _failedPrivateChannels.add(channelName);
    }
  }

  void removeFailedPrivateChannel(String channelName) {
    _failedPrivateChannels.remove(channelName);
  }

  Future<void> retryFailedPrivateChannels() async {
    if (_failedPrivateChannels.isEmpty) return;
    debugPrint(
      '[Echo] Retrying failed private channels: $_failedPrivateChannels',
    );
    final List<String> retried = [];
    for (final channelName in List.of(_failedPrivateChannels)) {
      try {
        await private(channelName);
        retried.add(channelName);
        debugPrint('[Echo] Retry success: $channelName');
      } catch (e) {
        debugPrint('[Echo] Retry failed: $channelName, error: $e');
      }
    }
    for (final name in List.of(retried)) {
      removeFailedPrivateChannel(name);
    }
  }

  Future<T> _enqueueAuth<T>(Future<T> Function() action) async {
    return await action();
  }

  Echo({
    required String key,
    required String wsHost,
    required String host,
    required String scheme,
    required String sanctumToken,
    int wsPort = 80,
    int wssPort = 443,
    String authUrl = '/broadcasting/auth',
  }) : _config = EchoConfig(
         key: key,
         wsHost: wsHost,
         host: host,
         scheme: scheme,
         sanctumToken: sanctumToken,
         wsPort: wsPort,
         wssPort: wssPort,
         authUrl: authUrl,
       ) {
    _wsManager = WebSocketManager(_config);
  }

  /// Getter for all registered channels
  Map<String, EchoChannel> get channels => _channels;

  /// Check if a specific channel is connected
  bool isChannelConnected(String channelName) =>
      _channelConnected[channelName] == true;

  /// Mark a channel as connected
  void _markChannelConnected(String channelName) =>
      _channelConnected[channelName] = true;

  /// Mark a channel as disconnected
  void _markChannelDisconnected(String channelName) =>
      _channelConnected[channelName] = false;

  /// Create a new channel with optional private flag
  Future<EchoChannel> createChannel(
    String channelName, {
    bool isPrivate = false,
  }) async => await _createChannel(channelName, isPrivate: isPrivate);

  /// Create a private channel (requires authentication)
  /// @param channelName The name of the private channel
  /// @return EchoChannel instance for the private channel
  Future<EchoChannel> private(
    String channelName, {
    bool allowReconnect = true,
  }) async {
    if (!_channels.containsKey(channelName) ||
        _shouldCreateConnection(channelName, true)) {
      _channels[channelName] = await _createChannel(
        channelName,
        isPrivate: true,
        allowReconnect: allowReconnect,
      );
      debugPrint('[Echo] $channelName Channel Created!');
    }

    return _channels[channelName]!;
  }

  /// Internal method to create a WebSocket channel
  /// @param channelName Name of the channel to create
  /// @param isPrivate Whether this is a private channel requiring auth
  /// @return EchoChannel instance
  Future<EchoChannel> _createChannel(
    String channelName, {
    bool isPrivate = false,
    int maxAttemps = 50,
    bool allowReconnect = true,
  }) async {
    // Prevent concurrent creation for the same channel
    if (_channels.containsKey(channelName) &&
        !_shouldCreateConnection(channelName, isPrivate)) {
      return _channels[channelName]!;
    }
    if (_channelStates[channelName] == ChannelState.connecting) {
      int wait = 0;
      while (_channelStates[channelName] == ChannelState.connecting &&
          wait < 100) {
        await Future.delayed(const Duration(milliseconds: 50));
        wait++;
      }
      if (_channels.containsKey(channelName)) return _channels[channelName]!;
    }
    if (_wsManager.channel == null) {
      await _initializeConnection();
    }
    if (_channelStates.containsKey(channelName) &&
        channels.containsKey(channelName) &&
        (_channelConnected.containsKey(channelName) &&
            _channelConnected[channelName]!)) {
      return channels[channelName]!;
    }
    _channelStates[channelName] = ChannelState.connecting;

    final channel = EchoChannel(
      wsManager: _wsManager,
      config: _config,
      isPrivate: isPrivate,
      listeners: _channels[channelName]?.listeners,
      channelName: channelName,
      echoInstance: this,
    );

    // Wait for socket ID to be available for private channels
    if (isPrivate) {
      int attempts = 0;
      while (_wsManager.socketId == null && attempts < maxAttemps) {
        await Future.delayed(const Duration(milliseconds: 100));
        attempts++;
      }

      try {
        if (_wsManager.socketId == null) {
          throw Exception(
            '[Echo] Socket ID not available after connection establishment',
          );
        }
        await _enqueueAuth(() async {
          await channel.authenticateAndSubscribe(channelName);
        });

        _markChannelConnected(channelName);
        _channelStates[channelName] = ChannelState.connected;
        removeFailedPrivateChannel(channelName);
      } catch (e) {
        _channelStates.remove(channelName);

        debugPrint('[Echo] Private channel failed: $e');
        if (allowReconnect) {
          addFailedPrivateChannel(channelName);
          Future.delayed(const Duration(seconds: 5), () async {
            await retryFailedPrivateChannels();
          });
        }
      }
    }

    // For non-private channels, mark connected now
    if (!isPrivate) _markChannelConnected(channelName);
    _channels[channelName] = channel;

    return channel;
  }

  /// Determine if a new connection should be created
  bool _shouldCreateConnection(String channelName, bool isPrivate) {
    return (_wsManager.channel == null || isPrivate) &&
        !(_channelConnected[channelName] ?? false);
  }

  /// Initialize WebSocket connection and set up listeners
  Future _initializeConnection({force = false}) async {
    if (_connectionCompleter != null) {
      // Another connect in progress — wait for it
      await _connectionCompleter!.future;
      return;
    }

    _connectionCompleter = Completer<void>();
    try {
      final channel = await _wsManager.connect(force: force);
      if (!_isStreamListened) {
        _isStreamListened = true;
        channel.stream.listen(
          _handleIncomingMessage,
          onDone: _handleConnectionClosed,
          onError: _handleConnectionError,
          cancelOnError: false,
        );
      }
    } finally {
      _connectionCompleter?.complete();
      _connectionCompleter = null;
    }
  }

  /// Handle incoming WebSocket messages
  void _handleIncomingMessage(dynamic data) {
    try {
      final response = jsonDecode(data);
      final responseObj = MessageHandler.parseMessage(data);

      if (MessageHandler.isConnectionEstablished(response)) {
        _handleConnectionEstablished(responseObj);
      } else {
        _handleEventMessage(response, responseObj);
      }
    } catch (e) {
      debugPrint('[Echo] Error handling incoming message: $e');
    }
  }

  /// Handle connection establishment
  void _handleConnectionEstablished(dynamic responseObj) {
    _wsManager.setSocketId(responseObj['socket_id']);
    // Try to reconnect channels; log errors without causing recursion
    reconnectChannel().catchError((error) {
      debugPrint('[Echo] Error during reconnection: $error');
    });
  }

  Future<void> reconnectChannel() async {
    final entries = List.of(_channels.entries);
    for (var entry in entries) {
      final key = entry.key;
      final channel = entry.value;
      if (channel.isPrivate) {
        try {
          channel._authenticator?.clearAuthToken();
          await channel.authenticateAndSubscribe(key);
        } catch (e) {
          debugPrint('[Echo] Failed to reconnect to private channel $key: $e');
          _markChannelDisconnected(key);
          addFailedPrivateChannel(key);
        }
      }
    }

    if (_failedPrivateChannels.isNotEmpty) {
      // Try retrying failed channels with a small backoff
      await Future.delayed(const Duration(seconds: 2));
      await retryFailedPrivateChannels();
    }
  }

  /// Handle event messages
  void _handleEventMessage(dynamic response, dynamic responseObj) {
    _channels.forEach((channelName, channel) {
      channel.listeners.forEach((key, action) {
        final matches = MessageHandler.eventMatchesListener(
          response['event'],
          key,
        );

        if (response['event'] != null && matches) {
          action(responseObj);
        }
      });
    });
  }

  /// Handle connection closure
  void _handleConnectionClosed() async {
    debugPrint('[Echo] 🔴 WebSocket connection closed!');

    _isStreamListened = false;

    // Save driver channels before clearing
    final driverChannels = _channels.entries
        .where((entry) => entry.key.startsWith('driver.'))
        .toList();

    _wsManager
      .._channel = null
      .._socketId = null;

    _channels.forEach((channelName, _) {
      _markChannelDisconnected(channelName);
    });

    if (this._config.keepAlive) {
      debugPrint('[Echo] ⚠️ WebSocket closed. Waiting for reconnect...');
      _isStreamListened = false;
      await _initializeConnection(force: true)
          .then((res) {
            debugPrint(
              '[Echo] ✅ Reconnection successful, reconnecting channels...',
            );
            reconnectChannel();
          })
          .catchError((err) {
            debugPrint('[Echo] ❌ Reconnection failed: $err');
          });
    }
  }

  /// Handle connection errors
  void _handleConnectionError(dynamic error) async {
    debugPrint('[Echo] ❌ WebSocket Error: $error');
    _channels.forEach((channelName, channel) {
      _markChannelDisconnected(channelName);
    });
    debugPrint('[Echo] 🔄 Attempting to reconnect...');
    _isStreamListened = false;
    await _initializeConnection(force: true)
        .then((res) {
          debugPrint(
            '[Echo] ✅ Reconnection successful, reconnecting channels...',
          );
          reconnectChannel();
        })
        .catchError((err) {
          debugPrint('[Echo] ❌ Reconnection failed: $err');
        });
  }

  /// Subscribe to a public channel
  /// @param channelName Name of the channel to subscribe to
  /// @return Future<Echo> for method chaining
  Future<Echo> channel(String channelName) async {
    final wsChannel = await _createChannel(channelName);

    final subscription = {
      "event": "pusher:subscribe",
      "data": {"channel": channelName},
    };

    _channels[channelName] = wsChannel;
    wsChannel.wsManager.channel?.sink.add(jsonEncode(subscription));
    return this;
  }

  /// Register an event listener for the last created channel
  /// @param eventName Name of the event to listen for
  /// @param callback Function to call when event is received
  /// @param onDone Optional callback when connection is closed
  /// @param onError Optional callback for error handling
  /// @return Echo instance for method chaining
  Echo listen(
    String eventName,
    Function(dynamic) callback, {
    Function()? onDone,
    Function()? onError,
  }) {
    final ws = _channels.values.last;
    ws.listeners[eventName] = (response) {
      callback(response);
    };
    return this;
  }

  /// Disconnect from a specific channel
  /// @param channelName Name of the channel to disconnect from
  void disconnect(String channelName) {
    // Protect driver channels from accidental disconnect
    if (channelName.startsWith('driver.')) {
      print(
        '[Echo] ⚠️ WARNING: Attempting to disconnect driver channel: $channelName',
      );
      print(
        '[Echo] Driver channels should remain connected. Skipping disconnect.',
      );
      return;
    }

    print('[Echo] 🔌 Disconnecting channel: $channelName');

    // Send unsubscribe message to server
    if (_wsManager.channel != null) {
      try {
        final channel = _channels[channelName];
        if (channel == null) return;

        final unsubscribe = {
          'event': 'pusher:unsubscribe',
          'data': {
            'channel': channel.isPrivate ? 'private-$channelName' : channelName,
          },
        };

        _wsManager.channel?.sink.add(jsonEncode(unsubscribe));
        print('[Echo] ✅ Unsubscribe message sent for: $channelName');
      } catch (e, s) {
        // reportException(e, s);
        print('[Echo] ⚠️ Error sending unsubscribe: $e');
      }
    }

    // Clear listeners but DON'T close WebSocket connection
    _channels[channelName]?.close();
    _channels.remove(channelName);
    _channelStates.remove(channelName);

    if (_channelConnected.containsKey(channelName)) {
      _channelConnected.remove(channelName);
      print('[Echo] ✅ Channel $channelName disconnected!');
    }

    // Log remaining channels
    print('[Echo] Remaining channels: ${_channels.keys.toList()}');
    print('[Echo] WebSocket still connected: ${isConnected}');
  }

  /// Check if WebSocket connection is healthy
  bool get isConnected =>
      _wsManager.channel != null && _wsManager.socketId != null;

  /// Close all WebSocket connections and clean up resources
  /// This should be called when the app is shutting down
  void closeAllConnections() {
    debugPrint('[Echo] Closing all connections');
    for (var channel in _channels.values) {
      try {
        channel.close();
      } catch (e) {
        debugPrint('[Echo] Error closing channel: $e');
      }
    }

    _channels.clear();
    _wsManager.disconnect();
    _isStreamListened = false;
    debugPrint('[Echo] All connections closed');
  }
}
