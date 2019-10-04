#include "core.h"
#include "application.h"
#include "../systems/log.h"

namespace blimp
{

void Application::run()
{
    Log::instance()->init();
}

} // namespace blimp