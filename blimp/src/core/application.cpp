#include "core.h"
#include "application.h"
#include "system/log.h"
#include "system/engine.h"

namespace blimp
{

    void Application::run()
    {
        Log::instance()->init();
        Engine::instance()->init();

        Engine::instance()->run();

        Engine::instance()->shutdown();
        Log::instance()->shutdown();
    }

} // namespace blimp