require 'ldap'
require 'ldap/ldif'
require 'ldap/schema'
require 'ldap/control'

module LDAP
  unless const_defined?(:LDAP_OPT_ERROR_NUMBER)
    LDAP_OPT_ERROR_NUMBER = 0x0031
  end

  class Mod
    unless instance_method(:to_s).arity.zero?
      alias_method :original_to_s, :to_s
      def to_s
        inspect
      end
    end

    alias_method :_initialize, :initialize
    def initialize(op, type, vals)
      if (VERSION.split(/\./).collect {|x| x.to_i} <=> [0, 9, 7]) <= 0
        @op, @type, @vals = op, type, vals # to protect from GC
      end
      _initialize(op, type, vals)
    end
  end

  IMPLEMENT_SPECIFIC_ERRORS = {}
  {
    0x51 => "SERVER_DOWN",
    0x52 => "LOCAL_ERROR",
    0x53 => "ENCODING_ERROR",
    0x54 => "DECODING_ERROR",
    0x55 => "TIMEOUT",
    0x56 => "AUTH_UNKNOWN",
    0x57 => "FILTER_ERROR",
    0x58 => "USER_CANCELLED",
    0x59 => "PARAM_ERROR",
    0x5a => "NO_MEMORY",

    0x5b => "CONNECT_ERROR",
    0x5c => "NOT_SUPPORTED",
    0x5d => "CONTROL_NOT_FOUND",
    0x5e => "NO_RESULTS_RETURNED",
    0x5f => "MORE_RESULTS_TO_RETURN",
    0x60 => "CLIENT_LOOP",
    0x61 => "REFERRAL_LIMIT_EXCEEDED",
  }.each do |code, name|
    IMPLEMENT_SPECIFIC_ERRORS[code] =
      ActiveLdap::LdapError.define(code, name, self)
  end

  class Conn
    begin
      instance_method(:search_ext)
      @@have_search_ext = true
    rescue NameError
      @@have_search_ext = false
    end

    def paged_results_ctl(ctls)
      ctls.each do |ctl|
        return ctl if ctl.oid == LDAP::LDAP_CONTROL_PAGEDRESULTS
      end

      nil
    end

    def paged_search(base, scope, filter, attributes, limit, &block)
      # work around a bug with openldap
      page_size = 126
      cookie = ''
      critical = true

      loop do
        ber_string = LDAP::Control.encode( page_size, cookie)
        control = LDAP::Control.new( LDAP::LDAP_CONTROL_PAGEDRESULTS, ber_string, critical)

        search_ext(base, scope, filter, attributes,
                               false, [control], nil, 0, 0, limit || 0, &block)

        control = paged_results_ctl( @controls )
        if control then
          returned_size, cookie = control.decode
          page_size = returned_size.to_i if returned_size.to_i > 0
        else
          break
        end
     
        if cookie.empty? then
          break
        end
     end
    end

    def search_with_limit(base, scope, filter, attributes, limit, paged_results, &block)
      if @@have_search_ext
        if paged_results then
          paged_search(base, scope, filter, attributes, limit, &block)
        else
          search_ext(base, scope, filter, attributes,
                     false, nil, nil, 0, 0, limit || 0, &block)
        end
      else
        i = 0
        search(base, scope, filter, attributes) do |entry|
          i += 1
          block.call(entry)
          break if limit and limit <= i
        end
      end
    end

    def failed?
      not error_code.zero?
    end

    def error_code
      code = err
      code = get_option(LDAP_OPT_ERROR_NUMBER) if code.zero?
      code
    end

    def error_message
      if failed?
        LDAP.err2string(error_code)
      else
        nil
      end
    end

    def assert_error_code
      return unless failed?
      code = error_code
      message = error_message
      klass = ActiveLdap::LdapError::ERRORS[code]
      klass ||= IMPLEMENT_SPECIFIC_ERRORS[code]
      if klass.nil? and message == "Can't contact LDAP server"
        klass = ActiveLdap::ConnectionError
      end
      klass ||= ActiveLdap::LdapError
      raise klass, message
    end
  end
end
