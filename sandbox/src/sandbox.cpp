#include "sandbox_core.h"
#include "blimp.h"

class Sandbox : public blimp::Application
{
    virtual void run() override
    {
        Application::run();
        BLIMP_LOG("RUNNING");
    }
};

std::unique_ptr<blimp::Application> create_application()
{
    return std::make_unique<Sandbox>();
}
