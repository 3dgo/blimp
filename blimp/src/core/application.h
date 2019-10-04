#pragma once

namespace blimp
{

class Application
{
public:
    Application() = default;
    virtual ~Application() = default;

    virtual void run();
};

} // namespace blimp

extern std::unique_ptr<blimp::Application> create_application();