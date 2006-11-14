#
# bitclust/searcher.rb
#
# Copyright (C) 2006 Minero Aoki
#
# This program is free software.
# You can distribute/modify this program under the Ruby License.
#

require 'bitclust/methodnamepattern'
require 'bitclust/nameutils'
require 'bitclust/exception'
require 'rbconfig'
require 'optparse'

module BitClust

  class Searcher

    include NameUtils

    def initialize
      cmd = File.basename($0, '.*')
      @dbpath = nil
      @name = (/\Abitclust/ =~ cmd ? 'bitclust search' : 'refe')
      @describe_all = false
      @linep = false
      @target_type = nil
      @parser = OptionParser.new {|opt|
        opt.banner = "Usage: #{@name} <pattern>"
        unless cmd == 'bitclust'
          opt.on('-d', '--database=PATH', "Database location (default: #{dbpath_name()})") {|prefix|
            @dbpath = prefix
          }
        end
        opt.on('-a', '--all', 'Prints descriptions for all matched entries.') {
          @describe_all = true
        }
        opt.on('-l', '--line', 'Prints one entry in one line.') {
          @linep = true
        }
        opt.on('--class', 'Search class or module.') {
          @target_type = :class
        }
        opt.on('--version', 'Prints version and quit.') {
          if cmd == 'bitclust'
            puts "BitClust -- Next generation reference manual interface"
            exit 1
          else
            puts "ReFe version 2"
            exit 1
          end
        }
        opt.on('--help', 'Prints this message and quit.') {
          puts opt.help
          exit 0
        }
      }
    end

    attr_reader :parser

    def parse(argv)
      @parser.parse! argv
      case @target_type
      when :class
        unless argv.size == 1
          $stderr.puts "--class option requires only 1 argument"
          exit 1
        end
      else
        if argv.size > 3
          $stderr.puts "too many arguments (#{argv.size} for 2)"
          exit 1
        end
      end
      # FIXME
      #compiler = RDCompiler::Text.new
      compiler = Plain.new
      @view = TerminalView.new(compiler,
                              {:describe_all => @describe_all, :line => @linep})
    end

    def exec(db, argv)
      db ||= Database.new(@dbpath || dbpath())
      case @target_type
      when :class
        find_class db, argv[0]
      else
        case argv.size
        when 0
          show_all_classes db
        when 1
          find_class_or_method db, argv[0]
        when 2
          c, m = *argv
          find_method db, c, nil, m
        when 3
          c, t, m = *argv
          check_method_type t
          find_method db, c, t, m
        else
          raise "must not happen: #{argv.size}"
        end
      end
    end

    private

    def show_all_classes(db)
      @view.show_class db.classes
    end

    def find_class(db, c)
      @view.show_class db.search_classes(c)
    end

    def find_method(db, c, t, m)
      @view.show_method db.search_methods(MethodNamePattern.new(c, t, m))
    end

    def check_method_type(t)
      if t == '$'
        raise InvalidKey, "'$' cannot be used as method type"
      end
      unless typemark?(t)
        raise InvalidKey, "unknown method type: #{t.inspect}"
      end
    end

    def find_class_or_method(db, pattern)
      case pattern
      when /\A\$/   # Special variable.
        find_method db, 'Kernel', '$', pattern.sub(/\A\$/, '')
      when /[\#,]\.|\.[\#,]|[\#\.\,]/   # method spec
        find_method db, *parse_method_spec_pattern(pattern)
      when /::/   # Class name or constant name.
        find_constant db, pattern
      when /\A[A-Z]/   # Method name or class name, but class name is better.
        begin
          find_class db, pattern
        rescue ClassNotFound
          find_method db, nil, nil, pattern
        end
      else   # No hint.  Method name or class name.
        begin
          find_method db, nil, nil, pattern
        rescue MethodNotFound
          find_class db, pattern
        end
      end
    end

    def find_constant(db, pattern)
      # class lookup is faster
      find_class db, pattern
    rescue ClassNotFound
      cnames = pattern.split(/::/)
      name = cnames.pop
      find_method db, cnames.join('::'), '::', name
    end

    def parse_method_spec_pattern(pat)
      _m, _t, _c = pat.reverse.split(/([\#,]\.|\.[\#,]|[\#\.\,])/, 2)
      c = _c.reverse
      t = _t.tr(',', '#').sub(/\#\./, '.#')
      m = _m.reverse
      return c, t, m
    end

    def dbpath_name
      env_dbpath() or default_dbpath() or '(none)'
    end

    def dbpath
      env_dbpath() or default_dbpath() or
          raise InvalidDatabase, "database not found"
    end

    def env_dbpath
      [ 'REFE2_DATADIR', 'BITCLUST_DATADIR' ].each do |key|
        if ENV.key?(key)
          unless Database.datadir?(ENV[key])
            raise InvalidDatabase, "environment variable #{key} given but #{ENV[key]} is not a valid BitClust database"
          end
          return ENV[key]
        end
      end
      nil
    end

    def default_dbpath
      [ "#{::Config::CONFIG['datadir']}/refe2",
        "#{::Config::CONFIG['datadir']}/bitclust" ].each do |prefix|
        return prefix if Database.datadir?(prefix)
      end
      nil
    end

  end


  class Plain
    def compile(src)
      src
    end
  end


  class TerminalView

    def initialize(compiler, opts)
      @compiler = compiler
      @describe_all = opts[:describe_all]
      @line = opts[:line]
    end

    def show_class(cs)
      if cs.size == 1
        if @line
          print_names [cs.first.label]
        else
          describe_class cs.first
        end
      else
        if @describe_all
          cs.sort.each do |c|
            describe_class c
          end
        else
          print_names cs.map {|c| c.labels }.flatten
        end
      end
    end

    def show_method(result)
      if result.determined?
        if @line
          print_names result.names
        else
          describe_method result.record
        end
      else
        if @describe_all
          result.records.sort.each do |rec|
            describe_method rec
          end
        else
          print_names result.names
        end
      end
    end

    private

    def print_names(names)
      if @line
        names.sort.each do |n|
          puts n
        end
      else
        print_packed_names names.sort
      end
    end

    def print_packed_names(names)
      max = terminal_column()
      buf = ''
      names.each do |name|
        if buf.size + name.size + 1 > max
          if buf.empty?
            puts name
            next
          end
          puts buf
          buf = ''
        end
        buf << name << ' '
      end
      puts buf unless buf.empty?
    end

    def terminal_column
      (ENV['COLUMNS'] || 70).to_i
    end

    def describe_class(c)
      unless c.library.name == '_builtin'
        puts "require '#{c.library.name}'"
        puts
      end
      puts "#{c.type} #{c.name}#{c.superclass ? " < #{c.superclass.name}" : ''}"
      unless c.included.empty?
        puts
        c.included.each do |mod|
          puts "include #{mod.name}"
        end
      end
      unless c.source.strip.empty?
        puts
        puts @compiler.compile(c.source.strip)
      end
    end

    def describe_method(rec)
      unless rec.entry.library.name == '_builtin'
        puts "require '#{rec.entry.library.name}'"
      end
      # FIXME: replace method signature by method spec
      unless rec.inherited_method?
        rec.names.each do |name|
          puts name
        end
      else
        rec.specs.each do |spec|
          puts "#{spec.klass}\t< #{rec.origin.klass}#{rec.origin.type}#{spec.method}"
        end
      end
      puts @compiler.compile(rec.entry.source.strip)
      puts
    end

  end

end