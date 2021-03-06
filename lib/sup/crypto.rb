begin
  require 'gpgme'
rescue LoadError
end

module Redwood

class CryptoManager
  include Singleton

  class Error < StandardError; end

  OUTGOING_MESSAGE_OPERATIONS = OrderedHash.new(
    [:sign, "Sign"],
    [:sign_and_encrypt, "Sign and encrypt"],
    [:encrypt, "Encrypt only"]
  )

  HookManager.register "gpg-options", <<EOS
Runs before gpg is called, allowing you to modify the options (most
likely you would want to add something to certain commands, like
{:always_trust => true} to encrypting a message, but who knows).

Variables:
operation: what operation will be done ("sign", "encrypt", "decrypt" or "verify")
options: a dictionary of values to be passed to GPGME

Return value: a dictionary to be passed to GPGME
EOS

  HookManager.register "sig-output", <<EOS
Runs when the signature output is being generated, allowing you to
add extra information to your signatures if you want.

Variables:
signature: the signature object (class is GPGME::Signature)
from_key: the key that generated the signature (class is GPGME::Key)

Return value: an array of lines of output
EOS

  def initialize
    @mutex = Mutex.new

    # test if the gpgme gem is available
    @gpgme_present =
      begin
        begin
          GPGME.check_version({:protocol => GPGME::PROTOCOL_OpenPGP})
          true
        rescue GPGME::Error
          false
        end
      rescue NameError
        false
      end

    return unless @gpgme_present

    if (bin = `which gpg2`.chomp) =~ /\S/
      GPGME.set_engine_info GPGME::PROTOCOL_OpenPGP, bin, nil
    end
  end

  def have_crypto?; @gpgme_present end

  def sign from, to, payload
    return unknown_status(cant_find_gpgme) unless @gpgme_present

    gpg_opts = {:protocol => GPGME::PROTOCOL_OpenPGP, :armor => true, :textmode => true}
    gpg_opts.merge(gen_sign_user_opts(from))
    gpg_opts = HookManager.run("gpg-options",
                               {:operation => "sign", :options => gpg_opts}) || gpg_opts

    begin
      sig = GPGME.detach_sign(format_payload(payload), gpg_opts)
    rescue GPGME::Error => exc
      info "Error while running gpg: #{exc.message}"
      raise Error, "GPG command failed. See log for details."
    end

    envelope = RMail::Message.new
    envelope.header["Content-Type"] = 'multipart/signed; protocol=application/pgp-signature'

    envelope.add_part payload
    signature = RMail::Message.make_attachment sig, "application/pgp-signature", nil, "signature.asc"
    envelope.add_part signature
    envelope
  end

  def encrypt from, to, payload, sign=false
    return unknown_status(cant_find_gpgme) unless @gpgme_present

    gpg_opts = {:protocol => GPGME::PROTOCOL_OpenPGP, :armor => true, :textmode => true}
    if sign
      gpg_opts.merge(gen_sign_user_opts(from))
      gpg_opts.merge({:sign => true})
    end
    gpg_opts = HookManager.run("gpg-options",
                               {:operation => "encrypt", :options => gpg_opts}) || gpg_opts
    recipients = to + [from]

    begin
      cipher = GPGME.encrypt(recipients, format_payload(payload), gpg_opts)
    rescue GPGME::Error => exc
      info "Error while running gpg: #{exc.message}"
      raise Error, "GPG command failed. See log for details."
    end

    encrypted_payload = RMail::Message.new
    encrypted_payload.header["Content-Type"] = "application/octet-stream"
    encrypted_payload.header["Content-Disposition"] = 'inline; filename="msg.asc"'
    encrypted_payload.body = cipher

    control = RMail::Message.new
    control.header["Content-Type"] = "application/pgp-encrypted"
    control.header["Content-Disposition"] = "attachment"
    control.body = "Version: 1\n"

    envelope = RMail::Message.new
    envelope.header["Content-Type"] = 'multipart/encrypted; protocol=application/pgp-encrypted'

    envelope.add_part control
    envelope.add_part encrypted_payload
    envelope
  end

  def sign_and_encrypt from, to, payload
    encrypt from, to, payload, true
  end

  def verified_ok? verify_result
    valid = true
    unknown = false
    all_output_lines = []
    all_trusted = true

    verify_result.signatures.each do |signature|
      output_lines, trusted = sig_output_lines signature
      all_output_lines << output_lines
      all_output_lines.flatten!
      all_trusted &&= trusted

      err_code = GPGME::gpgme_err_code(signature.status)
      if err_code == GPGME::GPG_ERR_BAD_SIGNATURE
        valid = false
      elsif err_code != GPGME::GPG_ERR_NO_ERROR
        valid = false
        unknown = true
      end
    end

    if all_output_lines.length == 0
      Chunk::CryptoNotice.new :valid, "Encrypted message wasn't signed", all_output_lines
    elsif valid
      if all_trusted
        Chunk::CryptoNotice.new(:valid, simplify_sig_line(verify_result.signatures[0].to_s), all_output_lines)
      else
        Chunk::CryptoNotice.new(:valid_untrusted, simplify_sig_line(verify_result.signatures[0].to_s), all_output_lines)
      end
    elsif !unknown
      Chunk::CryptoNotice.new(:invalid, simplify_sig_line(verify_result.signatures[0].to_s), all_output_lines)
    else
      unknown_status all_output_lines
    end
  end

  def verify payload, signature, detached=true # both RubyMail::Message objects
    return unknown_status(cant_find_gpgme) unless @gpgme_present

    gpg_opts = {:protocol => GPGME::PROTOCOL_OpenPGP}
    gpg_opts = HookManager.run("gpg-options",
                               {:operation => "verify", :options => gpg_opts}) || gpg_opts
    ctx = GPGME::Ctx.new(gpg_opts)
    sig_data = GPGME::Data.from_str signature.decode
    if detached
      signed_text_data = GPGME::Data.from_str(format_payload(payload))
      plain_data = nil
    else
      signed_text_data = nil
      plain_data = GPGME::Data.empty
    end
    begin
      ctx.verify(sig_data, signed_text_data, plain_data)
    rescue GPGME::Error => exc
      return unknown_status exc.message
    end
    self.verified_ok? ctx.verify_result
  end

  ## returns decrypted_message, status, desc, lines
  def decrypt payload, armor=false # a RubyMail::Message object
    return unknown_status(cant_find_gpgme) unless @gpgme_present

    gpg_opts = {:protocol => GPGME::PROTOCOL_OpenPGP}
    gpg_opts = HookManager.run("gpg-options",
                               {:operation => "decrypt", :options => gpg_opts}) || gpg_opts
    ctx = GPGME::Ctx.new(gpg_opts)
    cipher_data = GPGME::Data.from_str(format_payload(payload))
    plain_data = GPGME::Data.empty
    begin
      ctx.decrypt_verify(cipher_data, plain_data)
    rescue GPGME::Error => exc
      info "Error while running gpg: #{exc.message}"
      return Chunk::CryptoNotice.new(:invalid, "This message could not be decrypted", exc.message)
    end
    sig = self.verified_ok? ctx.verify_result
    plain_data.seek(0, IO::SEEK_SET)
    output = plain_data.read
    output.force_encoding Encoding::ASCII_8BIT if output.respond_to? :force_encoding

    ## TODO: test to see if it is still necessary to do a 2nd run if verify
    ## fails.
    #
    ## check for a valid signature in an extra run because gpg aborts if the
    ## signature cannot be verified (but it is still able to decrypt)
    #sigoutput = run_gpg "#{payload_fn.path}"
    #sig = self.old_verified_ok? sigoutput, $?

    if armor
      msg = RMail::Message.new
      # Look for Charset, they are put before the base64 crypted part
      charsets = payload.body.split("\n").grep(/^Charset:/)
      if !charsets.empty? and charsets[0] =~ /^Charset: (.+)$/
        output = Iconv.easy_decode($encoding, $1, output)
      end
      msg.body = output
    else
      # It appears that some clients use Windows new lines - CRLF - but RMail
      # splits the body and header on "\n\n". So to allow the parse below to
      # succeed, we will convert the newlines to what RMail expects
      output = output.gsub(/\r\n/, "\n")
      # This is gross. This decrypted payload could very well be a multipart
      # element itself, as opposed to a simple payload. For example, a
      # multipart/signed element, like those generated by Mutt when encrypting
      # and signing a message (instead of just clearsigning the body).
      # Supposedly, decrypted_payload being a multipart element ought to work
      # out nicely because Message::multipart_encrypted_to_chunks() runs the
      # decrypted message through message_to_chunks() again to get any
      # children. However, it does not work as intended because these inner
      # payloads need not carry a MIME-Version header, yet they are fed to
      # RMail as a top-level message, for which the MIME-Version header is
      # required. This causes for the part not to be detected as multipart,
      # hence being shown as an attachment. If we detect this is happening,
      # we force the decrypted payload to be interpreted as MIME.
      msg = RMail::Parser.read output
      if msg.header.content_type =~ %r{^multipart/} && !msg.multipart?
        output = "MIME-Version: 1.0\n" + output
        output.force_encoding Encoding::ASCII_8BIT if output.respond_to? :force_encoding
        msg = RMail::Parser.read output
      end
    end
    notice = Chunk::CryptoNotice.new :valid, "This message has been decrypted for display"
    [notice, sig, msg]
  end

private

  def unknown_status lines=[]
    Chunk::CryptoNotice.new :unknown, "Unable to determine validity of cryptographic signature", lines
  end

  def cant_find_gpgme
    ["Can't find gpgme gem."]
  end

  ## here's where we munge rmail output into the format that signed/encrypted
  ## PGP/GPG messages should be
  def format_payload payload
    payload.to_s.gsub(/(^|[^\r])\n/, "\\1\r\n")
  end

  # remove the hex key_id and info in ()
  def simplify_sig_line sig_line
    sig_line.sub(/from [0-9A-F]{16} /, "from ")
  end

  def sig_output_lines signature
    # It appears that the signature.to_s call can lead to a EOFError if
    # the key is not found. So start by looking for the key.
    ctx = GPGME::Ctx.new
    begin
      from_key = ctx.get_key(signature.fingerprint)
      first_sig = signature.to_s.sub(/from [0-9A-F]{16} /, 'from "') + '"'
    rescue EOFError
      from_key = nil
      first_sig = "No public key available for #{signature.fingerprint}"
    end

    time_line = "Signature made " + signature.timestamp.strftime("%a %d %b %Y %H:%M:%S %Z") +
                " using " + key_type(from_key, signature.fingerprint) +
                "key ID " + signature.fingerprint[-8..-1]
    output_lines = [time_line, first_sig]

    trusted = false
    if from_key
      # first list all the uids
      if from_key.uids.length > 1
        aka_list = from_key.uids[1..-1]
        aka_list.each { |aka| output_lines << '                aka "' + aka.uid + '"' }
      end

      # now we want to look at the trust of that key
      if signature.validity != GPGME::GPGME_VALIDITY_FULL && signature.validity != GPGME::GPGME_VALIDITY_MARGINAL
        output_lines << "WARNING: This key is not certified with a trusted signature!"
        output_lines << "There is no indication that the signature belongs to the owner"
      else
        trusted = true
      end

      # finally, run the hook
      output_lines << HookManager.run("sig-output",
                               {:signature => signature, :from_key => from_key})
    end
    return output_lines, trusted
  end

  def key_type key, fpr
    return "" if key.nil?
    subkey = key.subkeys.find {|subkey| subkey.fpr == fpr || subkey.keyid == fpr }
    return "" if subkey.nil?

    case subkey.pubkey_algo
    when GPGME::PK_RSA then "RSA "
    when GPGME::PK_DSA then "DSA "
    when GPGME::PK_ELG then "ElGamel "
    when GPGME::PK_ELG_E then "ElGamel "
    end
  end

  # logic is:
  # if    gpgkey set for this account, then use that
  # elsif only one account,            then leave blank so gpg default will be user
  # else                                    set --local-user from_email_address
  def gen_sign_user_opts from
    account = AccountManager.account_for from
    account ||= AccountManager.default_account
    if !account.gpgkey.nil?
      opts = {:signers => account.gpgkey}
    elsif AccountManager.user_emails.length == 1
      # only one account
      opts = {}
    else
      opts = {:signers => from}
    end
    opts
  end
end
end
