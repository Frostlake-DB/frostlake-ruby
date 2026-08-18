# frozen_string_literal: true

source "https://rubygems.org"

# Runtime dependencies (none) and development ones come from the gemspec.
gemspec

# Ships with Ruby, but is a bundled rather than a default gem from 3.4 on, so a
# bundler run has to ask for it. The driver works without it — fixed-point cells
# fall back to Float — and this keeps the tests exercising the exact path.
gem "bigdecimal"
