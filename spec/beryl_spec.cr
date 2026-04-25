require "./spec_helper"

describe Beryl do
  it "expose une version" do
    Beryl::VERSION.should eq("0.1.64")
  end
end
