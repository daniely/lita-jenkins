# lita-jenkins

[![Gem Version](https://badge.fury.io/rb/lita-jenkins.svg)](https://badge.fury.io/rb/lita-jenkins)
[![Build Status](https://travis-ci.org/daniely/lita-jenkins.svg?branch=master)](https://travis-ci.org/daniely/lita-jenkins)

Interact with your Jenkins CI server

## Installation

Add lita-jenkins to your Lita instance's Gemfile:

``` ruby
gem "lita-jenkins"
```

## Configuration

### Required attributes

* `url` (String) - Your Jenkins CI url. Default: `nil`.

### Optional attributes

* `auth` (String) - Your Jenkins CI username and password. Default: `nil`.

### Example

``` ruby
Lita.configure do |config|
  config.handlers.jenkins.url  = "http://test.com"
  config.handlers.jenkins.auth = "user1:sekret"
end
```

## Usage

```
 [You] Lita: jenkins list
[Lita]
[1] DISA chef_converge
[2] SUCC deploy
[3] FAIL build-all

 [You] Lita: jenkins list fail
[Lita]
[3] FAIL build-all
```
```

## License

[MIT](http://opensource.org/licenses/MIT)
