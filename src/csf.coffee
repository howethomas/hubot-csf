{Adapter,TextMessage,Robot} = require '../../hubot'

url = require 'url'
http = require 'http'
express = require 'express'
Events = require 'events'
Emitter = Events.EventEmitter
Redis = require "redis"
Os = require("os")
Request = require('request')
ReadWriteLock = require('rwlock')
Util = require('util')

class Csf extends Adapter

  constructor: (robot) ->
    super(robot)
    @active_numbers = []
    @pending_csf_requests = []

    @ee= new Emitter
    @robot = robot
    @userid= process.env.CSF_USERID
    @password= process.env.CSF_PASSWORD
    @THROTTLE_RATE_MS = 1500
    @CSF_SEND_MSG_URL = "https://wsapi.8mstext.com:2443/wsapi/rest"

    # Run a one second loop that checks to see if there are messages to be sent
    # to csf. Wait one second after the request is made to avoid
    # rate throttling issues.
    setInterval(@drain_csf, @THROTTLE_RATE_MS)


  report: (log_string) ->
    @robot.emit("log", log_string)

  drain_csf: () =>
    request = @pending_csf_requests.shift()
    if request?
      @report "Making request to #{request.url}"
      Request.post(
        request.url,
        request.options,
        (error, response, body) =>
          status_message = "Call to #{request.url} #{request.options.qs.msisdn}"
          if !error and response.statusCode == 200
            @report  status_message + " was successful."
          else
            @report  status_message +
            " failed with #{response.statusCode}:#{response.statusMessage}"
      )

  post_to_csf: (url, options) =>
    request =
      url: url
      options: options
    @pending_csf_requests.push request

  send_csf_message: (to, from, text) ->
    options =
      qs:
        userid: @userid
        password: @secret
        destnumber: to
        request: 'replyToText'
        sourcenumber: from
        shortmessage: text
    @post_to_csf(@CSF_SEND_MSG_URL, options)

  set_callback: (number, country, callback_path) =>
    @report "Setting number #{number} to #{callback_path}"
    options =
      qs:
        api_key: @key
        api_secret: @secret
        country: "US"
        msisdn: number
        moHttpUrl: callback_path
    @post_to_csf(@CSF_UPDATE_NUMBER_URL, options)

  send: (envelope, strings...) ->
    {user, room} = envelope
    user = envelope if not user # pre-2.4.2 style
    from = user.room
    to = user.name
    @send_csf_message(to, from, string) for string in strings

  emote: (envelope, strings...) ->
    @send envelope, "* #{str}" for str in strings

  reply: (envelope, strings...) ->
    strings = strings.map (s) -> "#{envelope.user.name}: #{s}"
    @send envelope, strings...

  run: ->
    self = @
    callback_path = process.env.CSF_CALLBACK_PATH or "/csf_callback"
    listen_port = process.env.CSF_LISTEN_PORT
    routable_address = process.env.CSF_CALLBACK_URL

    callback_url = "#{routable_address}#{callback_path}"
    app = express()
    app.get callback_path, (req, res) =>
      # First, see if this user is in the system.
      # If not, then let's make a new user for this far end.
      #
      res.writeHead 200,     "Content-Type": "text/plain"
      res.write "Message received"
      res.end()

      @report "Just got an inbound... #{req.query}"
      if req.query.msisdn?
        user_name = user_id = req.query.msisdn
        message_id = req.query.messageId
        room_name = req.query.to
        user = @robot.brain.userForId user_name,
          name: user_name, room: room_name
        inbound_message = new TextMessage user, req.query.text, message_id
        @robot.receive inbound_message
        @report "Received #{req.query.text} from #{req.query.msisdn} \
                bound for #{req.query.to}"
        return

    server = app.listen(listen_port, ->
      host = server.address().address
      port = server.address().port
      console.log "CSF listening locally at http://%s:%s", host, port
      console.log "External URL is #{callback_url}"
      return
    )

    @emit "connected"
    
exports.use = (robot) ->
  new Csf robot
