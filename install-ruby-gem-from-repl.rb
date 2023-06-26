How to install a ruby gem and load it directly in the console without changing the Gemfile:
```
gem_name = "ruby-progressbar"
`gem install #{gem_name}`
gem_folder_path = `gem which #{gem_name}`.strip.toutf8.gsub("#{gem_name}.rb", "")
$: << gem_folder_path
```
