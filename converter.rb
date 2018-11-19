file_path = 'hyper-schema.json'
yaml_save_path = 'output.yml'
json_save_path = 'output.json'
other_data_path = 'other_data.yml'
correct_data_path = 'correct.yaml'

check_correct_data = true

require 'json'
require 'yaml'
require 'json_schema'
require 'pry'

class GlobalStore
  attr_reader :pointer_to_ref, :ref_to_obj

  def initialize(other_data)
    @parameters = Hash.new
    @pointer_to_ref = Hash.new
    @ref_to_obj = Hash.new
    @anyof_objects = Array.new
    @schemas = Hash.new
    @other_data = other_data
  end

  def path_parameters
    @other_data['path_parameters']
  end

  def base_info
    @other_data['base_info']
  end

  def add_schema(key, obj)
    @schemas[key] = obj
  end

  def add_anyof(obj)
    @anyof_objects << obj
  end

  def add_parameters(pointer, value)
    key = convert_pointer_to_key(pointer)
    @parameters[convert_pointer_to_key(pointer)] = value
    key
  end

  def convert_pointer_to_key(pointer)
    pointer.gsub(/#\/definitions\//, '').gsub('/definitions/', '__')
  end

  def to_openapi3
    {
        parameters: @parameters.transform_values(&:to_openapi3),
        schemas: @schemas.transform_values(&:to_openapi3)
    }
  end

  def register_pointer(pointer, openapi3_ref, object)
    @pointer_to_ref[pointer] = openapi3_ref
    @ref_to_obj[openapi3_ref] = object
  end

  def register_pointers
    @parameters.values.each do |s|
      s.register_pointer("#/components/parameters")
    end

    @schemas.values.each { |s| s.register_pointer('#/components/schemas') }
  end

  def change_nullable
    @anyof_objects.each(&:change_nullable)
  end

  def add_path_parameters(openapi3_data)
    openapi3_data[:paths].each do |href, data|
      add_data = path_parameters[href]
      next unless add_data

      data['parameters'] = [] unless data['parameters']
      data['parameters'].concat(add_data)
    end
    openapi3_data
  end
end

class SchemaBase
  attr_reader :schema, :nullable
  def initialize(schema)
    @schema = schema
    @nullable = false
    build
  end

  def nullable!
    @nullable = true
  end

  def build

  end

  def to_openapi3
    nullable ? {nullable: true} : {}
  end

  def register_pointer(_parent)

  end

  def children
    []
  end
end

class ResponseObject < SchemaBase
  def build
    @response_schema =  SchemaObjectBuilder.new(schema).build!
  end

  def to_openapi3
    resp = super.merge({
        description: 'correct',
        content: {
            'application/json': {
                schema: @response_schema.to_openapi3,
            }
        },
    },)
    ['200', resp]
  end

  def register_pointer(parent)
    register_ref = parent + "/" + schema.name
    GLOBAL_STORE.register_pointer(schema.pointer, register_ref, self)

    @response_schema.register_pointer(register_ref)
  end
end

class ParameterObject < SchemaBase
  attr_reader :name
  def initialize(name, required, schema, in_param)
    @name = name
    @required = required
    @in_param = in_param

    super(schema)
  end

  def build
    @schema_object = SchemaObjectBuilder.new(schema).build!
  end

  def to_openapi3
    d = super.merge({
          name: name,
          in: @in_param,
          schema: @schema_object.to_openapi3
    })
    d.merge!(required: true) if @required
    d
  end

  def children
    []
  end

  def nullable!
    @schema_object.nullable!
  end

  def register_pointer(parent)
    pt = GLOBAL_STORE.convert_pointer_to_key(schema.pointer)
    GLOBAL_STORE.register_pointer(schema.pointer, parent + "/" + pt, self)
  end
end

class ParametersObject < SchemaBase
  def build
    required = schema.required.to_set
    @parameters = schema.properties.map { |k, v| ParameterObject.new(k, required.include?(k), v, 'query') }
  end

  def to_openapi3
    @parameters.map(&:to_openapi3)
  end
end

class MethodObject < SchemaBase
  def build
    raise "nil targetSchema in #{schema}, #{schema.pointer}" unless schema.target_schema
    @responses = [ ResponseObject.new(schema.target_schema) ]

    if schema.schema && !parameter_request?
      @request_body_schema = SchemaObjectBuilder.new(schema.schema).build!
    else
      @request_body_schema = nil
    end

    if schema.schema && parameter_request?
      required = schema.schema.required.nil? ? Set.new : schema.schema.required.to_set
      @parameters = schema.schema.properties.map do |k, v|
        if v.reference.nil?
          ParameterObject.new(k, required.include?(k), v, 'query')
        else
          ReferenceObject.new(v)
        end
      end
    else
      @parameters = []
    end
  end

  attr_accessor :description, :summary, :responses, :parameters

  def parameter_request?
    http_method == :get || http_method == :delete
  end

  def http_method
    schema.method
  end

  def request_body
    return nil unless @request_body_schema

    {
        content: {
            'application/json': {
                schema: @request_body_schema.to_openapi3,
            }
        }

    }
  end

  def to_openapi3
    resp = super.merge({ responses: responses.map(&:to_openapi3).to_h })

    (d = request_body) ? resp.merge!(requestBody: d) : nil

    resp.merge!(parameters: parameters.map(&:to_openapi3)) unless parameters.empty?

    (d = schema.title) ? resp.merge!(summary: d) : nil
    (d = schema.description) ? resp.merge!(description: d) : nil
    resp
  end
end

class LinkObject < SchemaBase
  attr_accessor :summary, :description, :http_methods, :openapi3_key, :href

  def initialize(schema, href)
    @href = href

    super(schema)
  end

  def build
    @http_methods = Hash.new
    schema.links.each do |link|
      next if link.href != href

      obj = MethodObject.new(link)
      http_method = obj.http_method

      raise "already exist #{http_method} in #{schema.pointer}" if @http_methods[http_method]
      @http_methods[http_method] = obj
    end

    schema.definitions.map do |k, v|
      data = ParameterObject.new(k, false, v, 'query')
      GLOBAL_STORE.add_parameters(v.pointer, data)
    end
  end

  def to_openapi3
    base = super
    base.merge!({
        summary: schema.title,
        description: schema.description,
    })
    base.merge!(http_methods.map { |k, v| [k, v.to_openapi3]}.to_h)
    base
  end

  def children
    @http_methods.values
  end

  def register_pointer(parent_ref)
    r = href.start_with?('/') ? href[1, href.length] : href
    register_ref = parent_ref.chomp('/') + '/' + r
    GLOBAL_STORE.register_pointer(schema.pointer, register_ref, self)

    children.each { |c| c.register_pointer(register_ref) }
  end
end

class AnyofObject < SchemaBase
  def to_openapi3
    if @references.size == 1
      @references.first.to_openapi3
    else
      {
          anyOf: @references.map(&:to_openapi3)
      }
    end
  end

  def change_nullable
    @references = schema.any_of.map do |ref|
      next nil if ref.type == ['null']

      obj = SchemaObjectBuilder.new(ref).build!

      if obj.is_a?(ReferenceObject)
        correct_ref = GLOBAL_STORE.pointer_to_ref[ref.reference.pointer]
        ref_object = GLOBAL_STORE.ref_to_obj[correct_ref]
        ref_object.nullable! if ref_object
      else
        obj.nullable!
      end


      obj
    end.compact
  end

  def register_pointer(parent_ref)
    register_ref = parent_ref.chomp('/') + '/' + File.basename(schema.pointer)
    GLOBAL_STORE.register_pointer(schema.pointer, register_ref, self)
  end
end

class NormalObject < SchemaBase
  def to_openapi3
    super.merge({
        description:schema.description,
        type: object_type,
        example: schema.default,
        enum: schema.enum,
    }).reject{ |_k, v| v.nil?}
  end

  def object_type
    types = schema.type.reject{|t| t == "null"}
    types.first # OpenAPI3 didin't support multi type (but Hype-Schema support)
  end

  def register_pointer(parent_ref)
    register_ref = parent_ref.chomp('/') + '/' + File.basename(schema.pointer)
    GLOBAL_STORE.register_pointer(schema.pointer, register_ref, self)
  end
end

class JsonSchemaObject < SchemaBase
  attr_reader :properties

  def build
    if schema.properties.empty? && schema.definitions.empty?
      @properties = {}
    else
      properties_objects = schema.properties.transform_values { |v| SchemaObjectBuilder.new(v).build! }
      definitions_objects = schema.definitions.transform_values { |v| SchemaObjectBuilder.new(v).build! }
      @properties = properties_objects.merge(definitions_objects)
    end
  end

  def required
    return nil if schema.required.nil? || schema.required.empty?

    schema.required
  end

  def any_of?
    !schema.any_of.empty?
  end

  def to_openapi3
    ret = super.merge({type: 'object'})

    ret.merge!(properties: properties.transform_values(&:to_openapi3)) unless properties.empty?
    (d = required) ? ret.merge!(required: d) : nil
    ret.merge!(description: schema.description) if schema.description

    ret
  end

  def register_pointer(parent_ref)
    register_ref = parent_ref.chomp('/') + '/' + File.basename(schema.pointer)
    GLOBAL_STORE.register_pointer(schema.pointer, register_ref, self)

    child_ref = register_ref + "/properties"
    properties.values.each do |child|
      child.register_pointer(child_ref)
    end
  end
end

class ReferenceObject < SchemaBase
  def to_openapi3
    correct_ref = GLOBAL_STORE.pointer_to_ref[schema.reference.pointer]
    if correct_ref
      {'$ref': correct_ref,}
    else
      {'$error_ref': schema.reference.pointer,}
    end
  end

  def register_pointer(parent_ref)
    register_ref = parent_ref.chomp('/') + '/' + File.basename(schema.pointer)
    GLOBAL_STORE.register_pointer(schema.pointer, register_ref, self)
  end
end

class ArrayObject < SchemaBase
  def build
    @items = SchemaObjectBuilder.new(schema.items).build!
  end

  def to_openapi3
    super.merge({
        type: 'array',
        items: @items.to_openapi3
    })
  end
end

class SchemaObjectBuilder
  attr_reader :schema
  def initialize(schema)
    @schema = schema
  end

  def has_link?
    !@schema.links.empty?
  end

  def object_type
    return 'paths' if has_link?
    return 'reference' if schema.reference
    return 'any_of' unless schema.any_of.empty?
    raise "OpenAPI3 unsupport multi type #{@schema.inspect}" if @schema.type.reject{|t| t == "null"}.size == 2 
    @schema.type.first
  end

  def nullable_type?
    @schema.type.include?("null")
  end

  def build!
    case object_type
    when 'paths'
      build_links
    when 'any_of'
      build_any_of
    when 'object'
      obj = JsonSchemaObject.new(schema)
      obj.nullable! if nullable_type?
      obj
    when 'reference'
      ReferenceObject.new(schema)
    when 'array'
      ArrayObject.new(schema)
    else
      n = NormalObject.new(schema)
      n.nullable! if nullable_type?
      n
    end
  end

  def build_links
    @schema.links.map(&:href).uniq.map{ |ref| LinkObject.new(schema, ref) }
  end

  def build_any_of
    obj = AnyofObject.new(schema)
    GLOBAL_STORE.add_anyof(obj)
    obj
  end
end

class OpenApi3Root
  attr_reader :schema, :paths
  def initialize(schema)
    @schema = schema
    @paths = Hash.new
  end

  def build!
    schema.definitions.each do |key, def_schema|
      obj = SchemaObjectBuilder.new(def_schema).build!
      if obj.is_a?(Array)
        obj.each do |l|
          raise 'invalid array' unless l.is_a?(LinkObject)
          raise "duplicate #{l.href} in #{schema.pointer}" if @paths[l.href]
          @paths[l.href] = l
        end
      else
        GLOBAL_STORE.add_schema(key, obj)
      end
    end

    register_pointers
    GLOBAL_STORE.change_nullable
  end

  def register_pointers
    @paths.values.each{ |s| s.register_pointer("#/paths/") }
    GLOBAL_STORE.register_pointers
  end

  def to_openapi3_yaml
    d = base_info
    d.merge!(paths: @paths.map { |k, v| [k, v.to_openapi3]}.to_h )
    d.merge!(components: GLOBAL_STORE.to_openapi3)

    d = GLOBAL_STORE.add_path_parameters(d)

    transform_hash(d)
  end

  def base_info
    title = schema.title || 'title'
    if schema.links
      urls = schema.links.map{ |s| {url: s.href} }
    else
      urls = [ {url: 'https://ota42y.com/'} ]
    end

    {
        openapi: '3.0.0',
        info: {
            version: '1.0.0',
            title: title
        },
        servers: urls
    }
  end

  def transform_hash(hash)
    hash.transform_keys!(&:to_s)
    hash.values.each do |v|
      transform_array(v) if v.is_a?(Array)
      transform_hash(v) if v.is_a?(Hash)
    end
    hash.keys.each do |k|
      hash[k] = hash[k].to_s if hash[k].is_a?(Symbol)
    end

    hash
  end

  def transform_array(array)
    array.each do |v|
      transform_hash(v) if v.is_a?(Hash)
    end

    array.each_with_index do |_, idx| _
      array[idx] = array[idx].to_s if array[idx].is_a?(Symbol)
    end
  end
end


schema_data = JSON.parse(File.read(file_path))
schema = JsonSchema.parse!(schema_data)

other_data = YAML.load_file(other_data_path)
GLOBAL_STORE = GlobalStore.new(other_data)

api = OpenApi3Root.new(schema)
api.build!
openapi_data = api.to_openapi3_yaml
open(yaml_save_path, 'w') { |f| f.write openapi_data.to_yaml }
open(json_save_path, 'w') { |f| f.write openapi_data.to_json }

if check_correct_data
  correct_data = YAML.load_file(correct_data_path)
  output_data = YAML.load_file(yaml_save_path)

  def deep_diff(a, b)
    (a.keys | b.keys).each_with_object({}) do |k, diff|
      if a[k] != b[k]
        if a[k].is_a?(Hash) && b[k].is_a?(Hash)
          diff[k] = deep_diff(a[k], b[k])
        else
          diff[k] = [a[k], b[k]]
        end
      end
      diff
    end
  end

  diff = deep_diff(output_data, correct_data)
  diff.each do |k,v|
    pp k
    pp v
    puts "----"
  end

  puts diff.empty? ? 'correct' : 'incorrect'
end
