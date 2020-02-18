#pragma once
#include "core/singleton.h"

namespace blimp
{

    template <typename T>
    class System : public Singleton<T>
    {
    public:
        virtual bool init() = 0;
        virtual void shutdown() = 0;
    };

} // namespace blimp