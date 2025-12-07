/**
 * WebSocket Backpressure — Flow Control for Slow Clients
 *
 * Package: websocket.backpressure
 *
 * Implements backpressure mechanisms to handle slow WebSocket clients:
 * - Send buffer tracking (bufferedAmount equivalent)
 * - High/low water marks with hysteresis
 * - Automatic slow client detection and disconnection
 * - Message priority queues (control > high > normal > low)
 * - Drain events when buffer empties
 *
 * This module provides a wrapper around WebSocketConnection that adds
 * flow control without modifying the core connection logic.
 *
 * Example:
 * ---
 * auto config = BackpressureConfig();
 * config.maxSendBufferSize = 4 * 1024 * 1024;  // 4MB max buffer
 * config.slowClientTimeout = 30.seconds;
 *
 * auto ws = new BackpressureWebSocket(connection, config);
 * ws.onDrain = () { log.info("Buffer drained, can send more"); };
 * ws.onSlowClient = () { log.warn("Slow client detected"); };
 *
 * // Send with priority
 * ws.send("important", MessagePriority.HIGH);
 * ws.send("normal data");  // Default: NORMAL priority
 *
 * // Check buffer state
 * if (ws.bufferedAmount > config.highWaterMark) {
 *     // Pause sending until drain event
 * }
 * ---
 *
 * Authors: Aurora WebSocket Contributors
 * License: MIT
 * Standards: Similar to HTML5 WebSocket bufferedAmount behavior
 */
module aurora_websocket.backpressure;

import core.time : Duration, MonoTime, seconds, msecs;
import core.sync.mutex : Mutex;
import std.algorithm : min, max, remove;
import std.container.binaryheap : BinaryHeap;

import aurora_websocket.connection : WebSocketConnection, WebSocketConfig;
import aurora_websocket.message : Message, MessageType, CloseCode;

// ============================================================================
// MESSAGE PRIORITY
// ============================================================================

/**
 * Priority levels for outgoing messages.
 *
 * Higher priority messages are sent first when the buffer is being drained.
 * Control frames (ping/pong/close) always have highest priority.
 */
enum MessagePriority : ubyte
{
    /// Control frames (ping, pong, close) - always sent first
    CONTROL = 0,
    
    /// High priority data - sent before normal messages
    HIGH = 1,
    
    /// Normal priority (default for user messages)
    NORMAL = 2,
    
    /// Low priority - sent only when buffer is mostly empty
    LOW = 3
}

// ============================================================================
// BACKPRESSURE STATE
// ============================================================================

/**
 * Current state of the backpressure flow control.
 */
enum BackpressureState : ubyte
{
    /// Normal operation - buffer below low water mark
    FLOWING = 0,
    
    /// Buffer above high water mark - should pause sending
    PAUSED = 1,
    
    /// Buffer full or slow client detected - may disconnect
    CRITICAL = 2
}

// ============================================================================
// CONFIGURATION
// ============================================================================

/**
 * Configuration for WebSocket backpressure.
 */
struct BackpressureConfig
{
    /// Maximum size of send buffer in bytes (default: 16MB)
    /// When exceeded, oldest low-priority messages may be dropped
    size_t maxSendBufferSize = 16 * 1024 * 1024;
    
    /// High water mark as ratio of maxSendBufferSize (default: 0.75)
    /// When buffer exceeds this, state becomes PAUSED
    double highWaterRatio = 0.75;
    
    /// Low water mark as ratio of maxSendBufferSize (default: 0.25)
    /// When buffer drops below this, state returns to FLOWING
    double lowWaterRatio = 0.25;
    
    /// Timeout for slow client detection (default: 30 seconds)
    /// If buffer stays above high water mark for this long, client is "slow"
    Duration slowClientTimeout = 30.seconds;
    
    /// Action to take when slow client is detected
    SlowClientAction slowClientAction = SlowClientAction.DISCONNECT;
    
    /// Maximum number of pending messages (default: 10000)
    /// Prevents memory exhaustion from many small messages
    size_t maxPendingMessages = 10_000;
    
    /// Interval for drain attempts when paused (default: 10ms)
    Duration drainInterval = 10.msecs;
    
    /// Enable message priority queue (default: true)
    /// If false, messages are sent in FIFO order
    bool enablePriorityQueue = true;
    
    /// Drop low priority messages when buffer is full (default: true)
    /// If false, rejects all new messages when full
    bool dropLowPriorityOnFull = true;
    
    // ────────────────────────────────────────────
    // Computed properties
    // ────────────────────────────────────────────
    
    /// Get absolute high water mark in bytes
    @property size_t highWaterMark() const @safe pure nothrow
    {
        return cast(size_t)(maxSendBufferSize * highWaterRatio);
    }
    
    /// Get absolute low water mark in bytes
    @property size_t lowWaterMark() const @safe pure nothrow
    {
        return cast(size_t)(maxSendBufferSize * lowWaterRatio);
    }
}

/**
 * Action to take when a slow client is detected.
 */
enum SlowClientAction : ubyte
{
    /// Disconnect the slow client immediately
    DISCONNECT = 0,
    
    /// Drop messages but keep connection open
    DROP_MESSAGES = 1,
    
    /// Just log warning, don't take action (useful for debugging)
    LOG_ONLY = 2,
    
    /// Call custom callback for handling
    CUSTOM = 3
}

// ============================================================================
// STATISTICS
// ============================================================================

/**
 * Statistics for backpressure monitoring.
 */
struct BackpressureStats
{
    /// Current amount of data buffered (bytes)
    size_t bufferedAmount;
    
    /// Number of messages currently queued
    size_t pendingMessages;
    
    /// Current backpressure state
    BackpressureState state;
    
    /// Total messages sent successfully
    ulong messagesSent;
    
    /// Total messages dropped due to buffer full
    ulong messagesDropped;
    
    /// Total bytes sent
    ulong bytesSent;
    
    /// Total bytes dropped
    ulong bytesDropped;
    
    /// Number of times state transitioned to PAUSED
    uint timesPaused;
    
    /// Number of times drain event fired
    uint drainEvents;
    
    /// Number of slow client detections
    uint slowClientDetections;
    
    /// Time spent in PAUSED state (total)
    Duration totalPausedTime;
    
    /// Peak buffer size observed
    size_t peakBufferedAmount;
    
    /// Maximum buffer size (from config, for utilization calculation)
    size_t maxBufferSize;
    
    /// Current buffer utilization (0.0 - 1.0)
    @property double utilization() const @safe pure nothrow
    {
        if (maxBufferSize == 0) return 0.0;
        return cast(double)bufferedAmount / cast(double)maxBufferSize;
    }
}

// ============================================================================
// PRIORITIZED MESSAGE
// ============================================================================

/**
 * A message with associated priority for queue ordering.
 */
private struct PrioritizedMessage
{
    /// The message data to send
    const(ubyte)[] data;
    
    /// Message type (text/binary)
    MessageType type;
    
    /// Priority level
    MessagePriority priority;
    
    /// Timestamp when message was queued
    MonoTime queuedAt;
    
    /// Size of the message data
    @property size_t size() const @safe pure nothrow
    {
        return data.length;
    }
    
    /// Compare for priority queue (lower priority value = higher priority)
    int opCmp(ref const PrioritizedMessage other) const @safe pure nothrow
    {
        // First compare by priority (lower enum value = higher priority)
        if (priority != other.priority)
            return cast(int)priority - cast(int)other.priority;
        
        // Same priority: FIFO order (earlier timestamp = higher priority)
        if (queuedAt < other.queuedAt) return -1;
        if (queuedAt > other.queuedAt) return 1;
        return 0;
    }
}

// ============================================================================
// SEND BUFFER
// ============================================================================

/**
 * Thread-safe send buffer with priority queue support.
 *
 * Messages are stored and retrieved based on priority. The buffer
 * tracks total size and enforces limits.
 */
class SendBuffer
{
    private PrioritizedMessage[] _queue;
    private size_t _totalSize;
    private size_t _maxSize;
    private size_t _maxMessages;
    private bool _usePriority;
    private Mutex _mutex;
    
    /// Statistics
    private ulong _messagesDropped;
    private ulong _bytesDropped;
    
    /**
     * Create a new send buffer.
     *
     * Params:
     *   maxSize = Maximum buffer size in bytes
     *   maxMessages = Maximum number of messages
     *   usePriority = Whether to use priority ordering
     */
    this(size_t maxSize, size_t maxMessages, bool usePriority) @trusted
    {
        _maxSize = maxSize;
        _maxMessages = maxMessages;
        _usePriority = usePriority;
        _totalSize = 0;
        _queue = [];
        _mutex = new Mutex();
    }
    
    /**
     * Enqueue a message for sending.
     *
     * Params:
     *   data = Message data
     *   type = Message type
     *   priority = Message priority
     *
     * Returns:
     *   true if message was queued, false if dropped
     */
    bool enqueue(const(ubyte)[] data, MessageType type, MessagePriority priority) @trusted
    {
        _mutex.lock();
        scope(exit) _mutex.unlock();
        
        auto msgSize = data.length;
        
        // Check if buffer is full
        if (_totalSize + msgSize > _maxSize || _queue.length >= _maxMessages)
        {
            // Try to drop low priority messages to make room
            if (!dropLowPriority(msgSize))
            {
                // Can't make room - drop this message if low priority
                if (priority >= MessagePriority.NORMAL)
                {
                    _messagesDropped++;
                    _bytesDropped += msgSize;
                    return false;
                }
                // High priority message on full buffer - drop oldest low priority
                dropLowPriority(_maxSize); // Drop as much as possible
            }
        }
        
        // Create message entry
        PrioritizedMessage msg;
        msg.data = data.dup;
        msg.type = type;
        msg.priority = priority;
        msg.queuedAt = MonoTime.currTime;
        
        // Insert into queue
        if (_usePriority)
        {
            // Insert in sorted order (simple insertion sort for small queues)
            insertSorted(msg);
        }
        else
        {
            // FIFO order
            _queue ~= msg;
        }
        
        _totalSize += msgSize;
        return true;
    }
    
    /**
     * Dequeue the highest priority message.
     *
     * Returns:
     *   The message, or null data if queue is empty
     */
    PrioritizedMessage dequeue() @trusted
    {
        _mutex.lock();
        scope(exit) _mutex.unlock();
        
        if (_queue.length == 0)
            return PrioritizedMessage.init;
        
        auto msg = _queue[0];
        _queue = _queue[1 .. $];
        _totalSize -= msg.size;
        
        return msg;
    }
    
    /**
     * Peek at the next message without removing it.
     */
    PrioritizedMessage peek() @trusted
    {
        _mutex.lock();
        scope(exit) _mutex.unlock();
        
        if (_queue.length == 0)
            return PrioritizedMessage.init;
        
        return _queue[0];
    }
    
    /**
     * Check if buffer is empty.
     */
    @property bool empty() @trusted
    {
        _mutex.lock();
        scope(exit) _mutex.unlock();
        return _queue.length == 0;
    }
    
    /**
     * Get current buffer size in bytes.
     */
    @property size_t size() @trusted
    {
        _mutex.lock();
        scope(exit) _mutex.unlock();
        return _totalSize;
    }
    
    /**
     * Get number of pending messages.
     */
    @property size_t length() @trusted
    {
        _mutex.lock();
        scope(exit) _mutex.unlock();
        return _queue.length;
    }
    
    /**
     * Get number of messages dropped.
     */
    @property ulong messagesDropped() @trusted
    {
        _mutex.lock();
        scope(exit) _mutex.unlock();
        return _messagesDropped;
    }
    
    /**
     * Get bytes dropped.
     */
    @property ulong bytesDropped() @trusted
    {
        _mutex.lock();
        scope(exit) _mutex.unlock();
        return _bytesDropped;
    }
    
    /**
     * Clear all pending messages.
     */
    void clear() @trusted
    {
        _mutex.lock();
        scope(exit) _mutex.unlock();
        
        _bytesDropped += _totalSize;
        _messagesDropped += _queue.length;
        _queue = [];
        _totalSize = 0;
    }
    
    // ────────────────────────────────────────────
    // Private helpers
    // ────────────────────────────────────────────
    
    private void insertSorted(PrioritizedMessage msg) @safe
    {
        // Find insertion point
        size_t insertPos = _queue.length;
        foreach (i, ref existing; _queue)
        {
            if (msg < existing)
            {
                insertPos = i;
                break;
            }
        }
        
        // Insert at position
        if (insertPos >= _queue.length)
            _queue ~= msg;
        else
            _queue = _queue[0 .. insertPos] ~ msg ~ _queue[insertPos .. $];
    }
    
    private bool dropLowPriority(size_t neededSpace) @safe
    {
        // Find and drop low priority messages from the end
        size_t freedSpace = 0;
        size_t[] toRemove;
        
        foreach_reverse (i, ref msg; _queue)
        {
            if (msg.priority >= MessagePriority.LOW)
            {
                toRemove ~= i;
                freedSpace += msg.size;
                if (freedSpace >= neededSpace)
                    break;
            }
        }
        
        if (freedSpace < neededSpace)
            return false;
        
        // Remove messages (in reverse order to maintain indices)
        foreach (i; toRemove)
        {
            _messagesDropped++;
            _bytesDropped += _queue[i].size;
            _totalSize -= _queue[i].size;
            _queue = _queue[0 .. i] ~ _queue[i + 1 .. $];
        }
        
        return true;
    }
}

// ============================================================================
// BACKPRESSURE WEBSOCKET
// ============================================================================

/// Callback types
alias DrainCallback = void delegate() @safe;
alias SlowClientCallback = void delegate() @safe;
alias StateChangeCallback = void delegate(BackpressureState oldState, BackpressureState newState) @safe;

/**
 * WebSocket wrapper with backpressure support.
 *
 * Wraps a WebSocketConnection to add flow control, buffering, and
 * slow client detection without modifying the underlying connection.
 */
class BackpressureWebSocket
{
    private WebSocketConnection _connection;
    private BackpressureConfig _config;
    private SendBuffer _sendBuffer;
    private BackpressureState _state;
    private MonoTime _pausedSince;
    private bool _slowClientDetected;
    
    // Statistics
    private ulong _messagesSent;
    private ulong _bytesSent;
    private uint _timesPaused;
    private uint _drainEvents;
    private uint _slowClientDetections;
    private Duration _totalPausedTime;
    private size_t _peakBufferedAmount;
    
    // Callbacks
    private DrainCallback _onDrain;
    private SlowClientCallback _onSlowClient;
    private StateChangeCallback _onStateChange;
    
    /**
     * Create a backpressure-enabled WebSocket wrapper.
     *
     * Params:
     *   connection = Underlying WebSocket connection
     *   config = Backpressure configuration
     */
    this(WebSocketConnection connection, BackpressureConfig config = BackpressureConfig.init) @trusted
    {
        _connection = connection;
        _config = config;
        _state = BackpressureState.FLOWING;
        _slowClientDetected = false;
        
        _sendBuffer = new SendBuffer(
            config.maxSendBufferSize,
            config.maxPendingMessages,
            config.enablePriorityQueue
        );
    }
    
    // ────────────────────────────────────────────
    // Properties
    // ────────────────────────────────────────────
    
    /// Check if connection is still open
    @property bool connected() @safe nothrow
    {
        return _connection.connected;
    }
    
    /// Get underlying connection (for advanced use)
    @property WebSocketConnection connection() @safe nothrow
    {
        return _connection;
    }
    
    /// Get current buffered amount in bytes
    @property size_t bufferedAmount() @trusted
    {
        return _sendBuffer.size;
    }
    
    /// Get current backpressure state
    @property BackpressureState state() const @safe nothrow
    {
        return _state;
    }
    
    /// Check if buffer is above high water mark
    @property bool isPaused() const @safe nothrow
    {
        return _state != BackpressureState.FLOWING;
    }
    
    /// Check if slow client was detected
    @property bool isSlowClient() const @safe nothrow
    {
        return _slowClientDetected;
    }
    
    /// Get buffer utilization (0.0 - 1.0)
    @property double bufferUtilization() @trusted
    {
        return cast(double)_sendBuffer.size / cast(double)_config.maxSendBufferSize;
    }
    
    // ────────────────────────────────────────────
    // Callbacks
    // ────────────────────────────────────────────
    
    /// Set callback for drain events (buffer dropped below low water mark)
    @property void onDrain(DrainCallback cb) @safe nothrow { _onDrain = cb; }
    
    /// Set callback for slow client detection
    @property void onSlowClient(SlowClientCallback cb) @safe nothrow { _onSlowClient = cb; }
    
    /// Set callback for state changes
    @property void onStateChange(StateChangeCallback cb) @safe nothrow { _onStateChange = cb; }
    
    // ────────────────────────────────────────────
    // Sending
    // ────────────────────────────────────────────
    
    /**
     * Send a text message with optional priority.
     *
     * Params:
     *   text = UTF-8 text to send
     *   priority = Message priority (default: NORMAL)
     *
     * Returns:
     *   true if message was queued/sent, false if dropped
     */
    bool send(string text, MessagePriority priority = MessagePriority.NORMAL) @safe
    {
        return sendData(cast(const(ubyte)[])text, MessageType.Text, priority);
    }
    
    /**
     * Send binary data with optional priority.
     *
     * Params:
     *   data = Binary data to send
     *   priority = Message priority (default: NORMAL)
     *
     * Returns:
     *   true if message was queued/sent, false if dropped
     */
    bool send(const(ubyte)[] data, MessagePriority priority = MessagePriority.NORMAL) @safe
    {
        return sendData(data, MessageType.Binary, priority);
    }
    
    /**
     * Send a ping frame (always high priority).
     */
    void ping(const(ubyte)[] data = null) @safe
    {
        _connection.ping(data);
    }
    
    /**
     * Send a pong frame (always high priority).
     */
    void pong(const(ubyte)[] data = null) @safe
    {
        _connection.pong(data);
    }
    
    /**
     * Close the connection.
     */
    void close(CloseCode code = CloseCode.Normal, string reason = "") @trusted
    {
        // Flush remaining high-priority messages
        flushHighPriority();
        
        _connection.close(code, reason);
    }
    
    // ────────────────────────────────────────────
    // Receiving
    // ────────────────────────────────────────────
    
    /**
     * Receive the next message (blocking).
     *
     * Also attempts to drain send buffer after receiving.
     */
    Message receive() @safe
    {
        auto msg = _connection.receive();
        
        // Opportunistically drain buffer after receive
        drainBuffer();
        
        return msg;
    }
    
    // ────────────────────────────────────────────
    // Buffer Management
    // ────────────────────────────────────────────
    
    /**
     * Attempt to drain the send buffer.
     *
     * Sends as many queued messages as possible without blocking.
     * Call this periodically or after receiving messages.
     *
     * Returns:
     *   Number of messages sent
     */
    size_t drainBuffer() @trusted
    {
        if (_sendBuffer.empty)
            return 0;
        
        size_t sent = 0;
        
        while (!_sendBuffer.empty)
        {
            auto msg = _sendBuffer.dequeue();
            if (msg.data.length == 0)
                break;
            
            try
            {
                if (msg.type == MessageType.Text)
                    _connection.send(cast(string)msg.data);
                else
                    _connection.send(msg.data);
                
                _messagesSent++;
                _bytesSent += msg.size;
                sent++;
            }
            catch (Exception e)
            {
                // Re-queue on failure? For now, drop
                break;
            }
        }
        
        // Update state after drain
        updateState();
        
        return sent;
    }
    
    /**
     * Flush only high-priority messages.
     *
     * Used during close to ensure control frames are sent.
     */
    void flushHighPriority() @trusted
    {
        while (!_sendBuffer.empty)
        {
            auto msg = _sendBuffer.peek();
            if (msg.priority > MessagePriority.HIGH)
                break;
            
            _sendBuffer.dequeue();
            
            try
            {
                if (msg.type == MessageType.Text)
                    _connection.send(cast(string)msg.data);
                else
                    _connection.send(msg.data);
                
                _messagesSent++;
                _bytesSent += msg.size;
            }
            catch (Exception)
            {
                break;
            }
        }
    }
    
    /**
     * Get current statistics.
     */
    BackpressureStats getStats() @trusted
    {
        BackpressureStats stats;
        stats.bufferedAmount = _sendBuffer.size;
        stats.pendingMessages = _sendBuffer.length;
        stats.state = _state;
        stats.messagesSent = _messagesSent;
        stats.messagesDropped = _sendBuffer.messagesDropped;
        stats.bytesSent = _bytesSent;
        stats.bytesDropped = _sendBuffer.bytesDropped;
        stats.timesPaused = _timesPaused;
        stats.drainEvents = _drainEvents;
        stats.slowClientDetections = _slowClientDetections;
        stats.totalPausedTime = _totalPausedTime;
        stats.peakBufferedAmount = _peakBufferedAmount;
        stats.maxBufferSize = _config.maxSendBufferSize;
        return stats;
    }
    
    // ────────────────────────────────────────────
    // Private implementation
    // ────────────────────────────────────────────
    
    private bool sendData(const(ubyte)[] data, MessageType type, MessagePriority priority) @trusted
    {
        // Try direct send if buffer is empty and state is FLOWING
        if (_state == BackpressureState.FLOWING && _sendBuffer.empty)
        {
            try
            {
                if (type == MessageType.Text)
                    _connection.send(cast(string)data);
                else
                    _connection.send(data);
                
                _messagesSent++;
                _bytesSent += data.length;
                return true;
            }
            catch (Exception)
            {
                // Fall through to buffer
            }
        }
        
        // Buffer the message
        bool queued = _sendBuffer.enqueue(data, type, priority);
        
        // Update peak
        auto currentSize = _sendBuffer.size;
        if (currentSize > _peakBufferedAmount)
            _peakBufferedAmount = currentSize;
        
        // Update state
        updateState();
        
        // Check for slow client
        checkSlowClient();
        
        return queued;
    }
    
    private void updateState() @trusted
    {
        auto oldState = _state;
        auto bufferSize = _sendBuffer.size;
        
        final switch (_state)
        {
            case BackpressureState.FLOWING:
                if (bufferSize >= _config.highWaterMark)
                {
                    _state = BackpressureState.PAUSED;
                    _pausedSince = MonoTime.currTime;
                    _timesPaused++;
                }
                break;
                
            case BackpressureState.PAUSED:
                if (bufferSize <= _config.lowWaterMark)
                {
                    _state = BackpressureState.FLOWING;
                    _totalPausedTime += MonoTime.currTime - _pausedSince;
                    _drainEvents++;
                    
                    // Fire drain callback
                    if (_onDrain !is null)
                    {
                        try { _onDrain(); } catch (Exception) {}
                    }
                }
                else if (bufferSize >= _config.maxSendBufferSize)
                {
                    _state = BackpressureState.CRITICAL;
                }
                break;
                
            case BackpressureState.CRITICAL:
                if (bufferSize <= _config.lowWaterMark)
                {
                    _state = BackpressureState.FLOWING;
                    _totalPausedTime += MonoTime.currTime - _pausedSince;
                    _drainEvents++;
                    
                    if (_onDrain !is null)
                    {
                        try { _onDrain(); } catch (Exception) {}
                    }
                }
                else if (bufferSize < _config.highWaterMark)
                {
                    _state = BackpressureState.PAUSED;
                }
                break;
        }
        
        // Fire state change callback
        if (oldState != _state && _onStateChange !is null)
        {
            try { _onStateChange(oldState, _state); } catch (Exception) {}
        }
    }
    
    private void checkSlowClient() @trusted
    {
        if (_slowClientDetected)
            return;
        
        if (_state == BackpressureState.FLOWING)
            return;
        
        auto pausedDuration = MonoTime.currTime - _pausedSince;
        
        if (pausedDuration >= _config.slowClientTimeout)
        {
            _slowClientDetected = true;
            _slowClientDetections++;
            
            // Fire callback
            if (_onSlowClient !is null)
            {
                try { _onSlowClient(); } catch (Exception) {}
            }
            
            // Take action
            final switch (_config.slowClientAction)
            {
                case SlowClientAction.DISCONNECT:
                    try
                    {
                        _connection.close(CloseCode.PolicyViolation, "Slow client");
                    }
                    catch (Exception) {}
                    break;
                    
                case SlowClientAction.DROP_MESSAGES:
                    _sendBuffer.clear();
                    updateState();
                    break;
                    
                case SlowClientAction.LOG_ONLY:
                    // Just detection, no action
                    break;
                    
                case SlowClientAction.CUSTOM:
                    // Callback handles it
                    break;
            }
        }
    }
}

// ============================================================================
// UNIT TESTS
// ============================================================================

// Test 1: BackpressureConfig defaults
@("config defaults are sensible")
unittest
{
    auto config = BackpressureConfig();
    assert(config.maxSendBufferSize == 16 * 1024 * 1024);
    assert(config.highWaterRatio == 0.75);
    assert(config.lowWaterRatio == 0.25);
    assert(config.highWaterMark == 12 * 1024 * 1024);
    assert(config.lowWaterMark == 4 * 1024 * 1024);
}

// Test 2: SendBuffer enqueue/dequeue
@("send buffer basic operations")
unittest
{
    auto buffer = new SendBuffer(1024, 100, false);
    
    assert(buffer.empty);
    assert(buffer.size == 0);
    
    auto result = buffer.enqueue(cast(ubyte[])"hello", MessageType.Text, MessagePriority.NORMAL);
    assert(result);
    
    assert(!buffer.empty);
    assert(buffer.size == 5);
    assert(buffer.length == 1);
}

// Test 3: SendBuffer size limit
@("send buffer enforces size limit")
unittest
{
    auto buffer = new SendBuffer(10, 100, false);
    
    // First message fits
    assert(buffer.enqueue(cast(ubyte[])"hello", MessageType.Text, MessagePriority.NORMAL));
    assert(buffer.size == 5);
    
    // Second message exceeds limit - should be dropped (NORMAL priority)
    assert(!buffer.enqueue(cast(ubyte[])"world!", MessageType.Text, MessagePriority.NORMAL));
    assert(buffer.size == 5);
    assert(buffer.messagesDropped == 1);
}

// Test 4: SendBuffer priority ordering
@("send buffer respects priority")
unittest
{
    auto buffer = new SendBuffer(1024, 100, true);
    
    buffer.enqueue(cast(ubyte[])"low", MessageType.Text, MessagePriority.LOW);
    buffer.enqueue(cast(ubyte[])"normal", MessageType.Text, MessagePriority.NORMAL);
    buffer.enqueue(cast(ubyte[])"high", MessageType.Text, MessagePriority.HIGH);
    buffer.enqueue(cast(ubyte[])"control", MessageType.Text, MessagePriority.CONTROL);
    
    // Should dequeue in priority order
    auto msg1 = buffer.dequeue();
    assert(cast(string)msg1.data == "control");
    
    auto msg2 = buffer.dequeue();
    assert(cast(string)msg2.data == "high");
    
    auto msg3 = buffer.dequeue();
    assert(cast(string)msg3.data == "normal");
    
    auto msg4 = buffer.dequeue();
    assert(cast(string)msg4.data == "low");
}

// Test 5: SendBuffer FIFO when priority disabled
@("send buffer FIFO without priority")
unittest
{
    auto buffer = new SendBuffer(1024, 100, false);
    
    buffer.enqueue(cast(ubyte[])"first", MessageType.Text, MessagePriority.LOW);
    buffer.enqueue(cast(ubyte[])"second", MessageType.Text, MessagePriority.HIGH);
    buffer.enqueue(cast(ubyte[])"third", MessageType.Text, MessagePriority.NORMAL);
    
    // Should dequeue in FIFO order
    assert(cast(string)buffer.dequeue().data == "first");
    assert(cast(string)buffer.dequeue().data == "second");
    assert(cast(string)buffer.dequeue().data == "third");
}

// Test 6: SendBuffer message count limit
@("send buffer enforces message count limit")
unittest
{
    auto buffer = new SendBuffer(1024 * 1024, 3, false);
    
    assert(buffer.enqueue(cast(ubyte[])"1", MessageType.Text, MessagePriority.NORMAL));
    assert(buffer.enqueue(cast(ubyte[])"2", MessageType.Text, MessagePriority.NORMAL));
    assert(buffer.enqueue(cast(ubyte[])"3", MessageType.Text, MessagePriority.NORMAL));
    
    // Fourth message should be dropped
    assert(!buffer.enqueue(cast(ubyte[])"4", MessageType.Text, MessagePriority.NORMAL));
    assert(buffer.length == 3);
}

// Test 7: MessagePriority ordering
@("message priority comparison")
unittest
{
    assert(MessagePriority.CONTROL < MessagePriority.HIGH);
    assert(MessagePriority.HIGH < MessagePriority.NORMAL);
    assert(MessagePriority.NORMAL < MessagePriority.LOW);
}

// Test 8: BackpressureState enum values
@("backpressure state enum")
unittest
{
    assert(BackpressureState.FLOWING == cast(BackpressureState)0);
    assert(BackpressureState.PAUSED == cast(BackpressureState)1);
    assert(BackpressureState.CRITICAL == cast(BackpressureState)2);
}

// Test 9: SendBuffer clear
@("send buffer clear")
unittest
{
    auto buffer = new SendBuffer(1024, 100, false);
    
    buffer.enqueue(cast(ubyte[])"test1", MessageType.Text, MessagePriority.NORMAL);
    buffer.enqueue(cast(ubyte[])"test2", MessageType.Text, MessagePriority.NORMAL);
    assert(buffer.length == 2);
    
    buffer.clear();
    
    assert(buffer.empty);
    assert(buffer.length == 0);
    assert(buffer.messagesDropped == 2);
}

// Test 10: SendBuffer peek
@("send buffer peek doesn't remove")
unittest
{
    auto buffer = new SendBuffer(1024, 100, false);
    
    buffer.enqueue(cast(ubyte[])"test", MessageType.Text, MessagePriority.NORMAL);
    
    auto peeked = buffer.peek();
    assert(cast(string)peeked.data == "test");
    assert(buffer.length == 1);  // Still there
    
    auto dequeued = buffer.dequeue();
    assert(cast(string)dequeued.data == "test");
    assert(buffer.length == 0);
}

// Test 11: PrioritizedMessage comparison
@("prioritized message comparison")
unittest
{
    PrioritizedMessage high, low;
    high.priority = MessagePriority.HIGH;
    low.priority = MessagePriority.LOW;
    high.queuedAt = MonoTime.currTime;
    low.queuedAt = MonoTime.currTime;
    
    assert(high < low);
    assert(!(low < high));
}

// Test 12: BackpressureStats struct
@("backpressure stats initialized to zero")
unittest
{
    BackpressureStats stats;
    assert(stats.bufferedAmount == 0);
    assert(stats.messagesSent == 0);
    assert(stats.messagesDropped == 0);
}

// Test 13: Config water marks calculation
@("config water marks calculated correctly")
unittest
{
    BackpressureConfig config;
    config.maxSendBufferSize = 1000;
    config.highWaterRatio = 0.8;
    config.lowWaterRatio = 0.2;
    
    assert(config.highWaterMark == 800);
    assert(config.lowWaterMark == 200);
}

// Test 14: SlowClientAction enum
@("slow client action enum values")
unittest
{
    assert(SlowClientAction.DISCONNECT == cast(SlowClientAction)0);
    assert(SlowClientAction.DROP_MESSAGES == cast(SlowClientAction)1);
    assert(SlowClientAction.LOG_ONLY == cast(SlowClientAction)2);
    assert(SlowClientAction.CUSTOM == cast(SlowClientAction)3);
}

// Test 15: SendBuffer drops low priority on full
@("send buffer drops low priority when full")
unittest
{
    auto buffer = new SendBuffer(20, 100, true);
    
    // Fill with low priority
    buffer.enqueue(cast(ubyte[])"low1-data", MessageType.Text, MessagePriority.LOW);
    buffer.enqueue(cast(ubyte[])"low2-data", MessageType.Text, MessagePriority.LOW);
    
    assert(buffer.size == 18);
    
    // High priority should succeed by dropping low
    assert(buffer.enqueue(cast(ubyte[])"high", MessageType.Text, MessagePriority.HIGH));
    
    // Should have dropped at least one low priority
    assert(buffer.messagesDropped >= 1);
}

// Test 16: BackpressureStats utilization calculation
@("stats utilization calculation")
unittest
{
    BackpressureStats stats;
    stats.bufferedAmount = 500;
    stats.maxBufferSize = 1000;
    
    assert(stats.utilization == 0.5);
    
    stats.bufferedAmount = 0;
    assert(stats.utilization == 0.0);
    
    stats.maxBufferSize = 0;
    stats.bufferedAmount = 100;
    assert(stats.utilization == 0.0);  // Avoid division by zero
}
