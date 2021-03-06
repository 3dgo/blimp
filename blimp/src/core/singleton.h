#pragma once

namespace blimp
{

    template<typename T>
    class Singleton
    {
    public:
        Singleton(const Singleton &) = delete;

        Singleton &operator=(const Singleton &) = delete;

    protected:
        Singleton() = default;

        virtual ~Singleton() = default;

    public:
        inline static T *instance()
        {
            static std::unique_ptr<T> instance = std::make_unique<T>();
            return instance.get();
        }
    };

}