# echo_dart

A new Flutter project.

## Getting Started

This project is a starting point for a Flutter application.

A few resources to get you started if this is your first Flutter project:

- [Lab: Write your first Flutter app](https://docs.flutter.dev/get-started/codelab)
- [Cookbook: Useful Flutter samples](https://docs.flutter.dev/cookbook)

For help getting started with Flutter development, view the
[online documentation](https://docs.flutter.dev/), which offers tutorials,
samples, guidance on mobile development, and a full API reference.

# Echo WebSocket Client Documentation

## Overview

**Echo** is a Dart/Flutter WebSocket client for real-time communication with Pusher-compatible servers. It handles both public and private channel subscriptions with automatic authentication, reconnection, and event routing.

## Table of Contents

- [Installation & Setup](#installation--setup)
- [Configuration](#configuration)
- [Basic Usage](#basic-usage)
- [Public Channels](#public-channels)
- [Private Channels](#private-channels)
- [Event Listeners](#event-listeners)
- [Connection Management](#connection-management)
- [Error Handling](#error-handling)
- [API Reference](#api-reference)
- [Examples](#examples)

---

## Installation & Setup

### Dependencies

Add to your `pubspec.yaml`:

```yaml
dependencies:
  web_socket_channel: ^latest
  http: ^latest
```

### Project Structure

The Echo implementation consists of these main classes:

- **Echo**: Main class for managing WebSocket connections
- **EchoChannel**: Represents individual channels with event listeners
- **EchoConfig**: Configuration container for connection parameters
- **WebSocketManager**: Handles low-level WebSocket operations
- **PrivateChannelAuthenticator**: Manages private channel authentication
- **MessageHandler**: Parses and routes incoming messages

---

## Configuration

### Initialize Echo

```dart
final echo = Echo(
  key: 'your-app-key',
  wsHost: 'your-websocket-host.com',
  host: 'your-api-host.com',
  scheme: 'https',
  sanctumToken: 'your-auth-token',
  wsPort: 80,           // Optional, default: 80
  wssPort: 443,         // Optional, default: 443
  authUrl: '/broadcasting/auth',  // Optional
);
```

### Configuration Parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `key` | String | Yes | Your Pusher application key |
| `wsHost` | String | Yes | WebSocket server hostname |
| `host` | String | Yes | API server hostname for authentication |
| `scheme` | String | Yes | Protocol scheme (`https` or `http`) |
| `sanctumToken` | String | Yes | Laravel Sanctum authentication token |
| `wsPort` | int | No | WebSocket port (default: 80) |
| `wssPort` | int | No | Secure WebSocket port (default: 443) |
| `authUrl` | String | No | Authentication endpoint (default: `/broadcasting/auth`) |

---

## Basic Usage

### Step 1: Initialize Echo

```dart
final echo = Echo(
  key: ReverbConst.Key,
  wsHost: ReverbConst.WsHost,
  host: ReverbConst.Host,
  scheme: 'https',
  sanctumToken: authToken,
);
```

### Step 2: Subscribe to a Channel

```dart
// Public channel
final channel = await echo.channel('general');

// Private channel (requires authentication)
final privateChannel = await echo.private('driver.123');
```

### Step 3: Listen for Events

```dart
channel.listen('message.sent', (data) {
  print('Received: $data');
});
```

### Step 4: Cleanup

```dart
echo.disconnect('channel-name');
// or close all connections
echo.closeAllConnections();
```

---

## Public Channels

### Subscribe to Public Channel

Public channels don't require authentication:

```dart
final channel = await echo.channel('news-updates');

channel.listen('news.published', (data) {
  print('New article: ${data['title']}');
});
```

### Multiple Listeners on Same Channel

```dart
channel.listen('news.published', (data) {
  print('Listener 1: ${data['title']}');
});

channel.listen('news.deleted', (data) {
  print('Listener 2: Article deleted');
});
```

---

## Private Channels

### Subscribe to Private Channel

Private channels require authentication:

```dart
final privateChannel = await echo.private('driver.${userId}');

privateChannel.listen('.order.requested', (data) {
  final order = Order.fromJson(data['order']);
  handleNewOrder(order);
});
```

### Channel Naming Convention

- **Public channels**: Use plain names like `general`, `notifications`
- **Private channels**: Prefix with `private-` automatically (e.g., `driver.123` becomes `private-driver.123`)
- **Event names**: Typically prefixed with dot (e.g., `.order.requested`)

### Authentication Flow

1. Channel subscription is requested
2. Echo waits for socket ID from server
3. Sends authentication request to configured `authUrl`
4. Server validates and returns authentication token
5. Echo subscribes with authentication token
6. Event listeners are registered

### Failed Private Channels

Failed private channels are automatically retried:

```dart
// Channels will retry after 5 seconds if authentication fails
final failedChannels = echo.failedPrivateChannels;
print('Failed channels: $failedChannels');

// Manual retry
await echo.retryFailedPrivateChannels();
```

---

## Event Listeners

### Event Name Patterns

Echo supports multiple event name matching patterns:

```dart
// Pattern 1: Event name with leading dot
channel.listen('.order.requested', (data) {
  // Matches "order.requested"
});

// Pattern 2: Laravel event class format
channel.listen('App\\Events\\OrderRequested', (data) {
  // Matches Laravel namespace event
});

// Pattern 3: Direct match
channel.listen('order.requested', (data) {
  // Direct string match
});
```

### Removing Listeners

```dart
// Clear all listeners on a channel
channel.close();

// Disconnect channel entirely
echo.disconnect('channel-name');
```

### Chaining Listeners

```dart
echo.listen('notification.sent', (data) {
  print('Got notification: $data');
});
```

---

## Connection Management

### Check Connection Status

```dart
bool isConnected = echo.isConnected;
if (!isConnected) {
  print('WebSocket not connected');
}
```

### Check Channel Connection

```dart
bool channelReady = echo.isChannelConnected('driver.123');

// Or get all channels
Map<String, EchoChannel> channels = echo.channels;
```

### Automatic Reconnection

Echo automatically handles reconnection:

- **Connection closed**: Automatically attempts to reconnect
- **Keepalive**: Sends ping every 30 seconds to keep connection alive
- **Failed channels**: Retries failed private channels with exponential backoff
- **State preservation**: Resubscribes to channels after reconnection

### Manual Reconnection

```dart
// For private channels with allowReconnect
final channel = await echo.private('driver.123', allowReconnect: true);

// For channels without auto-reconnect
final channel = await echo.private('special.channel', allowReconnect: false);
```

### Disconnect and Cleanup

```dart
// Disconnect specific channel
echo.disconnect('channel-name');

// Close all connections and cleanup
echo.closeAllConnections();
```

⚠️ **Note**: Driver channels (starting with `driver.`) are protected from accidental disconnection.

---

## Error Handling

### Network Errors

```dart
try {
  await echo.private('driver.123');
} on SocketException catch (e) {
  print('Socket error: $e');
} catch (e) {
  print('Error: $e');
}
```

### Authentication Errors

Failed authentication triggers automatic retry:

```dart
// Monitor failed channels
if (echo.failedPrivateChannels.isNotEmpty) {
  print('Auth failed for: ${echo.failedPrivateChannels}');
  await echo.retryFailedPrivateChannels();
}
```

### Message Parsing Errors

Invalid message format is handled gracefully:

```dart
// Echo automatically handles malformed JSON
channel.listen('event.name', (data) {
  // data is guaranteed to be valid or null
});
```

---

## API Reference

### Echo Class

#### Properties

| Property | Type | Description |
|----------|------|-------------|
| `channels` | Map<String, EchoChannel> | All active channels |
| `isConnected` | bool | WebSocket connection status |
| `failedPrivateChannels` | List<String> | Channels that failed authentication |

#### Methods

| Method | Returns | Description |
|--------|---------|-------------|
| `channel(name)` | Future<Echo> | Subscribe to public channel |
| `private(name, allowReconnect)` | Future<EchoChannel> | Subscribe to private channel |
| `listen(event, callback)` | Echo | Register event listener |
| `isChannelConnected(name)` | bool | Check if channel is connected |
| `disconnect(name)` | void | Disconnect from channel |
| `closeAllConnections()` | void | Close all connections |
| `retryFailedPrivateChannels()` | Future<void> | Retry failed authentications |

### EchoChannel Class

| Method | Returns | Description |
|--------|---------|-------------|
| `listen(event, callback)` | void | Register event listener |
| `close()` | void | Clear listeners (keeps WebSocket open) |
| `authenticateAndSubscribe(name)` | Future<void> | Authenticate and subscribe |

---

## Examples

### Example 1: Driver Order Notifications

```dart
class OrderModel {
  late Echo echo;
  
  Future<void> initSocket(User user) async {
    echo = Echo(
      key: 'your-key',
      wsHost: 'your-ws-host',
      host: 'your-api-host',
      scheme: 'https',
      sanctumToken: authToken,
    );

    // Subscribe to driver channel
    final driverChannel = await echo.private('driver.${user.id}');

    // Listen for order requests
    driverChannel.listen('.order.ride.passenger.requested', (response) {
      final order = Order.fromJson(response['order']);
      handleNewOrder(order);
    });

    // Listen for order cancellations
    driverChannel.listen('.order.ride.driver.canceled', (response) {
      cancelOrder();
    });

    // Listen for ratings
    driverChannel.listen('.order.rating_submitted', (response) {
      final rating = OrderRatingTip.fromJson(response['order']);
      displayRating(rating);
    });
  }

  void cleanup() {
    echo.closeAllConnections();
  }
}
```

### Example 2: Real-time Chat

```dart
Future<void> listenToChat(int orderId) async {
  final chatChannel = await echo.private('orders.$orderId');

  chatChannel.listen('.chat.message.sent', (response) {
    final message = ChatMessage.fromJson(response);
    addMessageToUI(message);
  });

  chatChannel.listen('.chat.typing', (response) {
    showTypingIndicator(response['user_id']);
  });
}
```

### Example 3: Connection Health Check

```dart
Future<bool> ensureSocketConnection(User user) async {
  if (echo == null) {
    await initSocket(user);
    return true;
  }

  final isConnected = echo.isConnected;
  if (!isConnected) {
    await initSocket(user);
    return true;
  }

  // Check if driver channel exists and is connected
  final driverChannelName = 'driver.${user.id}';
  if (!echo.isChannelConnected(driverChannelName)) {
    await echo.private(driverChannelName);
    return true;
  }

  return true;
}
```

### Example 4: Retry Failed Channels

```dart
// Monitor and retry failed authentications
Timer.periodic(Duration(seconds: 10), (_) {
  if (echo.failedPrivateChannels.isNotEmpty) {
    debugPrint('Retrying ${echo.failedPrivateChannels.length} channels');
    echo.retryFailedPrivateChannels();
  }
});
```

---

## Best Practices

### 1. Use Environment Configuration

```dart
class ReverbConst {
  static const String Key = String.fromEnvironment('REVERB_KEY');
  static const String WsHost = String.fromEnvironment('REVERB_WS_HOST');
  static const String Host = String.fromEnvironment('REVERB_HOST');
}
```

### 2. Singleton Pattern

```dart
late Echo echo;

Future<void> initializeEcho(String authToken) async {
  echo = Echo(
    key: ReverbConst.Key,
    wsHost: ReverbConst.WsHost,
    host: ReverbConst.Host,
    scheme: 'https',
    sanctumToken: authToken,
  );
}
```

### 3. Cleanup on App Exit

```dart
void dispose() {
  echo?.closeAllConnections();
}
```

### 4. Handle Reconnection Gracefully

```dart
// Always check connection before using
if (echo.isConnected && echo.isChannelConnected('driver.$userId')) {
  // Safe to use
}
```

### 5. Use debugPrint for Logging

```dart
debugPrint('[Echo] Channel subscribed: $channelName');
// Only printed in debug mode, hidden in release builds
```

---

## Debugging

### Enable Debug Logging

Echo uses `debugPrint()` for all logging. Check logs in:
- Android: Logcat
- iOS: Xcode console
- Web: Browser developer console

### Common Issues

| Issue | Cause | Solution |
|-------|-------|----------|
| Connection timeout | Invalid host/port | Verify `wsHost`, `wsPort`, `wssPort` |
| Authentication failed | Invalid token | Check `sanctumToken` validity |
| No events received | Wrong event name | Verify event pattern matches backend |
| Memory leak | Not calling cleanup | Call `closeAllConnections()` in `dispose()` |

---

## Architecture Diagram

```
┌─────────────────────────────────────────────────┐
│                   Echo (Main)                    │
│                                                  │
│  - Manages channels                              │
│  - Handles connection state                      │
│  - Routes messages to listeners                  │
└────────────────┬────────────────────────────────┘
                 │
    ┌────────────┴────────────────┐
    │                             │
    ▼                             ▼
┌─────────────────┐    ┌─────────────────────────────┐
│ WebSocketManager│    │ PrivateChannelAuthenticator │
│                 │    │                             │
│ - Manages ws    │    │ - Authenticates channels    │
│ - Ping/Pong     │    │ - Manages tokens            │
│ - Connection    │    │ - Retries failed auths      │
└────────┬────────┘    └──────────┬──────────────────┘
         │                        │
         └────────────┬───────────┘
                      │
                      ▼
        ┌─────────────────────────┐
        │    EchoChannel(s)       │
        │                         │
        │ - Event listeners       │
        │ - Message handling      │
        └─────────────────────────┘
```

---

## Version History

- **v1.0**: Initial release with public/private channels, authentication, and reconnection

---

## License

This implementation is part of the HoDriv application.

---

## Support

For issues or questions regarding Echo WebSocket implementation:

1. Check the `[Echo]` debug logs
2. Verify configuration parameters
3. Ensure backend server is running
4. Check network connectivity
5. Review authentication token validity
