mohair = require 'mohair'
Promise = require 'bluebird'
_ = require 'lodash'

################################################################################
# helpers

helpers = {}

# escape that handles table schemas correctly:
# schemaAwareEscape('someschema.users') -> '"someschema"."users"
helpers.schemaAwareEscape = (string) ->
  string.split('.').map((str) -> "\"#{str}\"").join '.'

helpers.defaultMohair = mohair
  .escape(helpers.schemaAwareEscape)
  # return everything by default
  .returning('*')

# TODO better name
helpers.replacePlaceholders = (sql) ->
  # replace ?, ?, ... with $1, $2, ...
  index = 1
  sql.replace /\?/g, -> '$' + index++

helpers.ignoredArgumentWarning = (receiver) ->
  "you called #{receiver} with an argument but #{receiver} ignores all arguments. #{receiver} returns a promise and maybe you wanted to call that promise instead: #{receiver}.then(function(result) { ... })"

################################################################################
# core

mesa =

  clone: ->
    Object.create @

  # the magic behind mohair's fluent interface:
  # prototypically inherit from `this` and set `key` to `value`

  fluent: (key, value) ->
    object = @clone()
    object[key] = value
    return object

  _returnFirst: false
  returnFirst: (arg = true) ->
    @fluent '_returnFirst', arg

  table: (arg) ->
    @fluent '_mohair', @_mohair.table arg

  getTable: ->
    @_mohair.getTable()

  debug: (arg) ->
    @fluent '_debug', arg

################################################################################
# mass assignment protection

  _allowed: []
  allow: (columns...) ->
    @fluent '_allowed', _.flatten(columns)

  _isUnsafe: false
  unsafe: (isUnsafe = true) ->
    @fluent '_isUnsafe', isUnsafe

  pickAllowed: (record) ->
    if @_isUnsafe
      return record
    if @_allowed.length is 0
      throw new Error [
        'no columns are allowed.'
        'this will make .update() or .insert() fail.'
        'call .allow(columns...) with at least one column before .insert() or .update().'
        'alternatively call .unsafe() before to disable mass assignment protection altogether.'
      ].join(' ')
    _.pick record, @_allowed

################################################################################
# embedding associated data

  _primaryKey: 'id'
  primaryKey: (arg) ->
    @fluent '_primaryKey', arg
  getPrimaryKey: ->
    @_primaryKey

  embedBelongsTo: (records, table, options) ->
    condition = {}
    condition[options.primaryKey] = _.pick records, options.foreignKey
    options.table
      .where(condition)
      .then (otherRecords) ->
        grouped = _.groupBy otherRecords, options.primaryKey
        records.forEach (record) ->
          foreignKey = record[options.foreignKey]
          record[options.as] = grouped[foreignKey][0]
        return records

  # foreignKey in this table
  # primaryKey in other table
  queueEmbedBelongsTo: (table, options) ->
    @queueAfter (records) ->

    otherTableName = options.table?.getTable?()
    unless otherTableName?
      throw new Error 'options.table must be a mesa instance'
    options.foreignKey ?= otherTableName + '_id'
    options.primaryKey ?= otherTableName.getPrimaryKey()
    # TODO camelcase this
    options.as ?= tableName

    @after (records) ->

  queueEmbedHasOne: (options) ->
    # first()

################################################################################
# the underlying mohair query builder instance

  _mohair: helpers.defaultMohair

  # implementation of sql-fragment interface

  sql: (escape) ->
    @_mohair.sql(escape)
  params: ->
    @_mohair.params()

  # pass through to mohair

  raw: (args...) ->
    @_mohair.raw args...

  where: (args...) ->
    @fluent '_mohair', @_mohair.where args...
  having: (args...) ->
    @fluent '_mohair', @_mohair.having args...
  join: (args...) ->
    @fluent '_mohair', @_mohair.join args...
  select: (args...) ->
    @fluent '_mohair', @_mohair.select args...
  limit: (arg) ->
    @fluent '_mohair', @_mohair.limit arg
  offset: (arg) ->
    @fluent '_mohair', @_mohair.offset arg
  order: (arg) ->
    @fluent '_mohair', @_mohair.order arg
  group: (arg) ->
    @fluent '_mohair', @_mohair.group arg
  with: (arg) ->
    @fluent '_mohair', @_mohair.with arg
  returning: (args...) ->
    @fluent '_mohair', @_mohair.returning args...

################################################################################
# set and get connection

  setConnection: (arg) ->
    typeofArg = typeof arg
    unless ('function' is typeof arg) or (('object' is typeof arg) and arg.query?)
      throw new Error '.setConnection() must be called with either a connection object or a function that takes a callback and calls it with a connection'
    @fluent '_connection', arg

  getConnection: (arg) ->
    that = @
    if arg?
      throw new Error helpers.ignoredArgumentWarning '.getConnection()'
    connection = @_connection
    debug = @_debug

    unless connection?
      return Promise.reject new Error "the method you are calling requires a call to .setConnection() before it"

    new Promise (resolve, reject) ->
      if 'function' is typeof connection
        return connection (err, result, realDone) ->
          done = ->
            debug? 'connection', 'done', {}, {connection: connection}, that
            realDone()
          if err?
            done?()
            return reject err
          debug? 'connection', 'fresh', {}, {
            connection: result
            done: done
          }, that
          resolve
            connection: result
            done: done

      debug? 'connection', 'reuse', {}, {connection: connection}, that
      resolve
        connection: connection

################################################################################
# promise wrapper around node-postgres

  wrapInConnection: (block) ->
    @getConnection().then ({connection, done}) ->
      block(connection).finally ->
        done?()

  query: (sql, params) ->
    that = @
    debug = @_debug
    @wrapInConnection (connection) ->
      new Promise (resolve, reject) ->
        debug? 'query', 'before', {
          sql: sql,
          params: params
        }, {
          connection: connection
        }, that
        connection.query sql, params, (err, results) ->
          debug? 'query', 'after', {
            sql: sql
            params: params
          }, {
            connection: connection
            err: err
            results: results
          }, that
          if err?
            return reject err
          resolve results

  wrapInTransaction: (block) ->
    that = this
    debug = @_debug
    @wrapInConnection (connection) ->
      withConnection = that.setConnection(connection)
      debug? 'transaction', 'begin', {}, {connection: connection, block: block}, that
      withConnection.query('BEGIN;')
        .then ->
          block connection
        .then (result) ->
          debug? 'transaction', 'commit', {}, {connection: connection, block: block}, that
          withConnection.query('COMMIT;').then ->
            result
        .catch (error) ->
          debug? 'transaction', 'rollback', {error: error}, {
            connection: connection
            block: block
          }, that
          withConnection.query('ROLLBACK;').then ->
            Promise.reject error

################################################################################
# what happens after the promise returned by .query(sql, params) is resolved

  runQueue: (queue, value) ->
    context = @
    reducer = (soFar, step) ->
      soFar.then step.bind(context)
    queue.reduce reducer, Promise.resolve value

################################################################################
# what happens after the promise returned by .query(sql, params) is resolved
# but before the promise returned by the calling function
# (.select(), insert.(), ...) is resolved.

  afterQuery: (results, options) ->
    that = this
    debug = @_debug
    rows = results.rows
    unless rows
      return results

    debug? 'after-query', 'before-queue', {rows: rows}, options, that
    @runQueue(options.after, rows)
      .map @runQueue.bind(@, options.afterEach)
      .then (rows) ->
        debug? 'after-query', 'after-queue', {rows: rows}, options, that
        if options.returnFirst
          rows[0]
        else
          rows

################################################################################
# command: these functions have side effects

  insert: (args...) ->
    that = this
    debug = @_debug

    records = _.flatten args

    if records.length is 0
      throw new Error 'no records to insert'

    returnFirst = args.length is 1 and not Array.isArray(args[0])

    debug? 'insert', 'before-queue', {records: records}, {}, that

    @runQueue(@_queueBeforeInsert, records)
      .map @runQueue.bind(@, @_queueBeforeEachInsert)
      .then (records) ->
        debug? 'insert', 'after-queue', {records: records}, {}, that
        records.forEach (record, index) ->
          if Object.keys(record).length is 0
            throw new Error "insert would fail because record at index #{index} is empty after processing before queue"

        query = that._mohair.insert records
        sql = helpers.replacePlaceholders query.sql()

        that.query(sql, query.params()).then (results) ->
          that.afterQuery(results,
            returnFirst: returnFirst
            after: that._queueAfterInsert
            afterEach: that._queueAfterEachInsert
          )

  update: (update) ->
    that = this
    debug = @_debug

    debug? 'update', 'before-queue', {update: update}, {}, that

    @runQueue(@_queueBeforeEachUpdate, update).then (update) ->
      debug? 'update', 'after-queue', {update: update}, {}, that

      query = that._mohair.update update
      sql = helpers.replacePlaceholders query.sql()

      that.query(sql, query.params()).then (results) ->
        that.afterQuery results,
          returnFirst: that._returnFirst
          after: that._queueAfterUpdate
          afterEach: that._queueAfterEachUpdate

  delete: ->
    if arg?
      throw new Error helpers.ignoredArgumentWarning '.delete()'
    that = this

    query = that._mohair.delete()
    sql = helpers.replacePlaceholders query.sql()

    that.query(sql, query.params()).then (results) ->
      that.afterQuery results,
        returnFirst: that._returnFirst
        after: that._queueAfterDelete
        afterEach: that._queueAfterEachDelete

################################################################################
# query: these functions have no side effects

  find: (arg) ->
    if arg?
      throw new Error helpers.ignoredArgumentWarning '.find()'

    that = this

    sql = helpers.replacePlaceholders that.sql()

    that.query(sql, that.params()).then (results) ->
      that.afterQuery results,
        returnFirst: that._returnFirst
        after: that._queueAfterSelect
        afterEach: that._queueAfterEachSelect

  first: (arg) ->
    if arg?
      throw new Error helpers.ignoredArgumentWarning '.first()'

    @limit(1)
      .returnFirst()
      .find()

  exists: (arg) ->
    if arg?
      throw new Error helpers.ignoredArgumentWarning '.exists()'

    query = @_mohair.limit(1)
    sql = helpers.replacePlaceholders query.sql()

    @query(sql, query.params()).then (results) ->
      results.rows? and results.rows.length isnt 0

################################################################################
# helper functions

  # call a one-off function as if it were part of mesa
  call: (f, args...) ->
    f.apply @, args

  helpers: helpers

################################################################################
# automatic construction of setters and properties for queue:
# (automating this prevents copy & paste errors)

setQueueProperties = (object, suffix) ->
  setterPropertyName = 'queue' + suffix
  dataPropertyName = '_' + setterPropertyName
  object[dataPropertyName] = []
  object[setterPropertyName] = (args...) ->
    @fluent dataPropertyName, @[dataPropertyName].concat _.flatten(args)

# queueBeforeInsert, queueBeforeEachInsert
# queueBeforeEachUpdate (just that because the update is a single object/record)

setQueueProperties(mesa, 'BeforeInsert')
setQueueProperties(mesa, 'BeforeEachInsert')
setQueueProperties(mesa, 'BeforeEachUpdate')

# queueAfterSelect, queueAfterEachSelect
# queueAfterInsert, queueAfterEachInsert
# queueAfterUpdate, queueAfterEachUpdate
# queueAfterDelete, queueAfterEachDelete

for phase in ['Select', 'Insert', 'Update', 'Delete']
  setQueueProperties(mesa, 'After' + phase)
  setQueueProperties(mesa, 'AfterEach' + phase)

mesa.queueBeforeEach = (args...) ->
  object = @clone()
  ['Insert', 'Update'].forEach (phase) ->
    propertyName = '_queueBeforeEach' + phase
    object[propertyName] = object[propertyName].concat _.flatten(args)
  return object

mesa.queueAfter = (args...) ->
  object = @clone()
  ['Select', 'Insert', 'Update', 'Delete'].forEach (phase) ->
    propertyName = '_queueAfter' + phase
    object[propertyName] = object[propertyName].concat _.flatten(args)
  return object

mesa.queueAfterEach = (args...) ->
  object = @clone()
  ['Select', 'Insert', 'Update', 'Delete'].forEach (phase) ->
    propertyName = '_queueAfterEach' + phase
    object[propertyName] = object[propertyName].concat _.flatten(args)
  return object

################################################################################
# exports

module.exports = mesa
  # enable mass assignment protection
  .queueBeforeEach(mesa.pickAllowed)
