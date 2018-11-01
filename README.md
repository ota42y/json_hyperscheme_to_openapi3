# JSON Hyper-Schema to OpenAPI3

This script not support completely convert because there is no compatibility between them.  

# Usage

1. Update `schema.json' file by your JSON Hyper-Schema
2. Write path parameter OpenAPI3 definition to `other_data.yml`
    - Because JSON Hyper-Schema don't need write path parameter definition, but OpenAPI3 is required.
3. `bundle install`
4. `bundle exec ruby converter.rb`
5. Check output OpenAPI3 data in `output.yml` and `output.json` (there are same data)
