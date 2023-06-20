# Ruby exception inheritance

```ruby
module Phlex
  Error = Module.new

  NameError = Class.new(NameError) { include Error }
  ArgumentError = Class.new(ArgumentError) { include Error }
  StandardError = Class.new(StandardError) { include Error }
end
```
