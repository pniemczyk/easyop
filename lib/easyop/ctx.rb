module Easyop
  # Easyop::Ctx is the shared data bag passed through an operation (or flow of
  # operations). It replaces Interactor's Context with a faster, Hash-backed
  # implementation that avoids the deprecated OpenStruct.
  #
  # It doubles as the result object returned from Operation.call — the caller
  # inspects ctx.success? / ctx.failure? and reads output attributes directly.
  #
  # Key API:
  #   ctx.fail!                       # mark failed (raises Ctx::Failure internally)
  #   ctx.fail!(error: "Boom!")        # set attrs AND fail
  #   ctx.success? / ctx.ok?          # true unless fail! was called
  #   ctx.failure? / ctx.failed?      # true after fail!
  #   ctx.error                       # shortcut for ctx[:error]
  #   ctx.errors                      # shortcut for ctx[:errors] ({} by default)
  #   ctx[:key] / ctx.key             # attribute read
  #   ctx[:key] = v / ctx.key = v     # attribute write
  #   ctx.merge!(hash)                # bulk-set attributes
  #   ctx.on_success { |ctx| ... }    # chainable callback
  #   ctx.on_failure { |ctx| ... }    # chainable callback
  class Ctx
    # Raised (and swallowed by Operation#run) when fail! is called.
    # Propagates to callers of Operation#run! and Operation#call!.
    class Failure < StandardError
      attr_reader :ctx

      def initialize(ctx)
        @ctx = ctx
        super("Operation failed#{": #{ctx.error}" if ctx.error}")
      end
    end

    # ── Construction ────────────────────────────────────────────────────────

    def self.build(attrs = {})
      return attrs if attrs.is_a?(self)
      new(attrs)
    end

    def initialize(attrs = {})
      @attributes  = {}
      @failure     = false
      @rolled_back = false
      @called      = []   # interactors already run (for rollback)
      attrs.each { |k, v| self[k] = v }
    end

    # ── Attribute access ─────────────────────────────────────────────────────

    # Allows cancel_if / skip_if blocks written as { ctx[:key] } when evaluated
    # via instance_exec (self is the Ctx, so `ctx` resolves to this method).
    def ctx = self

    def [](key)
      @attributes[key.to_sym]
    end

    def []=(key, val)
      @attributes[key.to_sym] = val
    end

    def merge!(attrs = {})
      attrs.each { |k, v| self[k] = v }
      self
    end

    def to_h
      @attributes.dup
    end

    def key?(key)
      @attributes.key?(key.to_sym)
    end

    # Returns a plain Hash with only the specified keys.
    def slice(*keys)
      keys.each_with_object({}) do |k, h|
        sym = k.to_sym
        h[sym] = @attributes[sym] if @attributes.key?(sym)
      end
    end

    # ── Status ───────────────────────────────────────────────────────────────

    def success?
      !@failure
    end
    alias ok? success?

    def failure?
      @failure
    end
    alias failed? failure?

    # ── Fail! ────────────────────────────────────────────────────────────────

    # Mark the operation as failed. Accepts an optional hash of attributes to
    # merge into ctx before raising (e.g. error:, errors:).
    def fail!(attrs = {})
      merge!(attrs)
      @failure = true
      raise Failure, self
    end

    # ── Error conveniences ───────────────────────────────────────────────────

    def error
      self[:error]
    end

    def error=(msg)
      self[:error] = msg
    end

    def errors
      self[:errors] || {}
    end

    def errors=(hash)
      self[:errors] = hash
    end

    # ── Chainable result callbacks ────────────────────────────────────────────

    def on_success
      yield self if success?
      self
    end

    def on_failure
      yield self if failure?
      self
    end

    # ── Rollback support ──────────────────────────────────────────────────────

    # Called by Flow to track which operations have run.
    def called!(operation)
      @called << operation
      self
    end

    # Roll back already-called operations in reverse order.
    # Errors in individual rollbacks are swallowed to ensure all run.
    def rollback!
      return if @rolled_back
      @rolled_back = true
      @called.reverse_each do |op|
        op.rollback rescue nil
      end
    end

    # ── Pattern matching ──────────────────────────────────────────────────────

    # Supports: case result; in { success: true, user: } ...
    def deconstruct_keys(keys)
      base = { success: success?, failure: failure? }
      base.merge(@attributes).then do |all|
        keys ? all.slice(*keys) : all
      end
    end

    # ── Dynamic attribute access (method_missing) ─────────────────────────────

    def method_missing(name, *args)
      key = name.to_s
      if key.end_with?("=")
        self[key.chomp("=")] = args.first
      elsif key.end_with?("?")
        base = key.chomp("?").to_sym
        return !!self[base]
      elsif @attributes.key?(name.to_sym)
        self[name]
      else
        super
      end
    end

    def respond_to_missing?(name, include_private = false)
      key = name.to_s
      return true if key.end_with?("=")
      return true if key.end_with?("?")
      @attributes.key?(name.to_sym) || super
    end

    def inspect
      status = @failure ? "FAILED" : "ok"
      "#<Easyop::Ctx #{@attributes.inspect} [#{status}]>"
    end
  end
end
