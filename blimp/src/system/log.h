#pragma once

#include "system.h"
#include <spdlog/spdlog.h>
#include <spdlog/sinks/stdout_color_sinks.h>

namespace blimp
{

class Log : public System<Log>
{
public:
    virtual void init() override
    {
        spdlog::set_pattern("%^[%T] %n: %v%$");
        m_logger = spdlog::stdout_color_mt("BLIMP");
        m_logger->set_level(spdlog::level::trace);
    }

    virtual void shutdown() override
    {
    }

    spdlog::logger *logger()
    {
        return m_logger.get();
    }

private:
    std::shared_ptr<spdlog::logger> m_logger;
};

} // namespace blimp

#define BLIMP_LOG(...) blimp::Log::instance()->logger()->trace(__VA_ARGS__)