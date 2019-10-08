#include "core.h"
#include "application.h"
#include "system/log.h"

namespace blimp
{

void Application::run()
{
    Log::instance()->init();
}

} // namespace blimp