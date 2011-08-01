events = require('events')
uuid = require('node-uuid')

class Transport

Transport.CONNECTING = 0
Transport.OPEN = 1
Transport.CLOSING = 2
Transport.CLOSED = 3

closeFrame = (status, reason) ->
    return 'c' + JSON.stringify([status, reason])


MAP = {}

class Session extends events.EventEmitter
    constructor: (@session_id, server) ->
        @id  = uuid()
        @send_buffer = []
        @is_closing = false
        @readyState = Transport.CONNECTING
        if @session_id
            MAP[@session_id] = @
        @timeout_cb = => @didTimeout()
        @to_tref = setTimeout(@timeout_cb, 5000)
        @emit_open = =>
            @emit_open = null
            server.emit('open', @)

    register: (recv) ->
        if @recv
            recv.doSendFrame(closeFrame(2010, "Another connection still open"))
            return
        if @to_tref
            clearTimeout(@to_tref)
            @to_tref = null
        if @readyState is Transport.CLOSING
            recv.doSendFrame(@close_frame)
            @to_tref = setTimeout(@timeout_cb, 5000)
            return
        # Registering. From now on 'unregister' is responsible for
        # setting the timer.
        @recv = recv
        @recv.session = @

        # first, send the open frame
        if @readyState is Transport.CONNECTING
            @recv.doSendFrame('o')
            @readyState = Transport.OPEN
            # Emit the open event, but not right now
            process.nextTick @emit_open

        # At this point the transport might have gotten away (jsonp).
        if not @recv
            return
        @tryFlush()
        return

    unregister: ->
        @recv.session = null
        @recv = null
        if @to_tref
            clearTimeout(@to_tref)
        @to_tref = setTimeout(@timeout_cb, 5000)

    tryFlush: ->
        if @send_buffer.length > 0
            [sb, @send_buffer] = [@send_buffer, []]
            @recv.doSendBulk(sb)
        else
            if @recv.doKeepalive
                if @to_tref
                    clearTimeout(@to_tref)
                x = =>@recv.doKeepalive()
                # We have a timeout for konqeror - 15 seconds.
                @to_tref = setTimeout(x, 13000)
        return

    didTimeout: ->
        if @readyState isnt Transport.CONNECTING and
           @readyState isnt Transport.OPEN and
           @readyState isnt Transport.CLOSING
            throw Error('INVALID_STATE_ERR')
        if @recv
            throw Error('RECV_STILL_THERE')
        @readyState = Transport.CLOSED
        @emit('close', {status: 1001, reason: "Session timeouted"})
        if @session_id
            delete MAP[@session_id]
            @session_id = null

    didMessage: (payload) ->
        if @readyState is Transport.OPEN
            @emit('message', {data: payload})
        return

    send: (payload) ->
        if @readyState isnt Transport.OPEN
            throw Error('INVALID_STATE_ERR')
        @send_buffer.push( payload )
        if @recv
            @tryFlush()

    close: (status=1000, reason="Normal closure") ->
        if @readyState isnt Transport.OPEN
            return false
        @readyState = Transport.CLOSING
        @close_frame = closeFrame(status, reason)
        if @recv
            # Go away.
            @recv.doSendFrame(@close_frame)
            if @recv
                @unregister

    toString: ->
        r = ['#'+@id]
        if @session_id
            r.push( @session_id )
        if @recv
            r.push( @recv.protocol )
        return r.join('/')


Session.bySessionId = (session_id) ->
    return MAP[session_id] or null

Session.bySessionIdOrNew = (session_id, server) ->
    session = Session.bySessionId(session_id)
    if not session
        session = new Session(session_id, server)
    return session


class GenericReceiver
    constructor: (@thingy) ->
        @setUp(@thingy)

    setUp: ->
        @thingy_end_cb = () => @didClose(1006, "Connection closed")
        @thingy.addListener('end', @thingy_end_cb)

    tearDown: ->
        @thingy.removeListener('end', @thingy_end_cb)
        @thingy_end_cb = null

    didClose: (status, reason) ->
        if @thingy
            @tearDown(@thingy)
            try
                @thingy.end()
            catch x
            @thingy = null
        if @session
            @session.unregister(status, reason)

    doSendBulk: (messages) ->
        if messages.length is 1
            @doSendFrame('m' + JSON.stringify(messages[0]))
        else
            @doSendFrame('a' + JSON.stringify(messages))


# Write stuff directly to connection.
class ConnectionReceiver extends GenericReceiver
    constructor: (@connection) ->
        try
            @connection.setKeepAlive(true, 5000)
        catch x
        super @connection

    doSendFrame: (payload, encoding='utf-8') ->
        if not @connection
            return false
        try
            @connection.write(payload, encoding)
            return true
        catch e
        return false

    didClose: ->
        super
        @connection = null


# Write stuff to response, using chunked encoding if possible.
class ResponseReceiver extends GenericReceiver
    constructor: (@response) ->
        try
            @response.connection.setKeepAlive(true, 5000)
        catch x
        super (@response)

    doSendFrame: (payload) ->
        try
            @response.write(payload)
            return true
        catch x
        return false

    didClose: ->
        super
        @response = null


exports.Transport = Transport
exports.Session = Session
exports.ConnectionReceiver = ConnectionReceiver
exports.ResponseReceiver = ResponseReceiver
